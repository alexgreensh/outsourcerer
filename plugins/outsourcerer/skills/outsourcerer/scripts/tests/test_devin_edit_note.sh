#!/usr/bin/env bash
# Verify the edit prompt permits scoped checks and preserves the task's ledger classification.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

FAKE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FAKE_ROOT"' EXIT
mkdir -p "$FAKE_ROOT/bin"

# Fake devin: answers the auth preflight, records the prompt that follows -p.
cat > "$FAKE_ROOT/bin/devin" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then echo "Logged in"; exit 0; fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-p" ]; then printf '%s' "${2:-}" > "$DEVIN_CAPTURE"; echo ok; exit 0; fi
  shift
done
exit 1
EOF
chmod +x "$FAKE_ROOT/bin/devin"

pass=0 fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

export PATH="$FAKE_ROOT/bin:$PATH" HOME="$FAKE_ROOT" OSRC_HOME="$FAKE_ROOT/osrc" OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
unset OSRC_STREAM OSRC_RUN_ID OSRC_TASK_CLASS

# Each dispatch runs in a fresh shell with the script sourced (OSRC_SOURCED=1 skips main).
# A direct delegate() call is spend-gated and bare swe-2 is not proven Free: consent per call keeps
# this suite about the edit note (the refusal is test_devin_launch_gate's job).
prompt_for() { # <perm> [env...]
  local perm="$1"; shift
  local cap="$FAKE_ROOT/prompt.$perm.$#"
  env DEVIN_CAPTURE="$cap" "$@" bash -c 'f="$1"; perm="$2"; set --; OSRC_SOURCED=1; . "$f" >/dev/null 2>&1; PROVIDER=devin; OSRC_SPEND_OK=1 delegate "$perm" "" -m swe-2 "fix the parser"' _ "$SRC" "$perm" >/dev/null 2>&1
  cat "$cap" 2>/dev/null
}

# Same sourced-shell dispatch for an arbitrary task; the captured prompt lands in
# $FAKE_ROOT/prompt.class and stdout carries "want=<bare task class> got=<recorded task_class>"
# so the edit note can be proven unable to skew the ledger row's classification.
ledger_class_for() { # <perm> <task>
  local perm="$1" task="$2" cap="$FAKE_ROOT/prompt.class"
  env DEVIN_CAPTURE="$cap" bash -c 'f="$1"; perm="$2"; task="$3"; set --; OSRC_SOURCED=1; . "$f" >/dev/null 2>&1; PROVIDER=devin
    OSRC_SPEND_OK=1 delegate "$perm" "" -m swe-2 "$task" >/dev/null 2>&1
    printf "want=%s got=%s\n" "$(_classify_task "$task")" "$(tail -n 1 "$OSRC_LEDGER" 2>/dev/null | jq -r .task_class 2>/dev/null)"' _ "$SRC" "$perm" "$task" 2>/dev/null
}

p="$(prompt_for accept-edits)"
grep -q 'fix the parser' <<<"$p" \
  && ok "edit prompt still carries the task" || bad "edit prompt lost the task: $p"
grep -q 'run the task.*own unit tests and requested --check' <<<"$p" \
  && ok "edit prompt asks for task-scoped verification" || bad "edit prompt lost verification"

p="$(prompt_for auto)"
grep -q 'fix the parser' <<<"$p" && ok "read-only (auto) prompt still dispatches the task" || bad "read-only (auto) prompt was not captured"
grep -q 'Finish your edits' <<<"$p" \
  && bad "read-only (auto) prompt got the edit note" \
  || ok "read-only (auto) prompt is unchanged"

p="$(prompt_for accept-edits OSRC_DEVIN_EDIT_NOTE=0)"
grep -q 'fix the parser' <<<"$p" || bad "opt-out edit prompt was not captured"
grep -q 'Finish your edits' <<<"$p" \
  && bad "OSRC_DEVIN_EDIT_NOTE=0 did not remove the note" \
  || ok "OSRC_DEVIN_EDIT_NOTE=0 leaves the edit prompt untouched"

# The note keys on the perm string, so pin the verb -> perm mapping it depends on.
grep -qE '^[[:space:]]+edit\)[[:space:]]+route_delegate "accept-edits"' "$SRC" \
  && ok "the edit verb dispatches with accept-edits (the perm the note keys on)" \
  || bad "the edit verb no longer dispatches with accept-edits; the note would silently stop attaching"

# The appended note is dispatch plumbing, not task text: its own wording ("make the code
# changes", "verify", "run the relevant checks") would otherwise reach record_ledger and flip
# a SIMPLE edit task's task_class to code. The recorded class must be the bare task's class, while the
# prompt devin actually receives still carries task + note together.
cl="$(ledger_class_for accept-edits "say hi")"
case "$cl" in
  *"want=simple got=simple"*) ok "ledger: task_class is the bare task's class (note excluded)" ;;
  *) bad "ledger: the edit note skewed task_class ($cl)" ;;
esac
p="$(cat "$FAKE_ROOT/prompt.class" 2>/dev/null)"
grep -q 'say hi' <<<"$p" && grep -q 'Finish your edits' <<<"$p" \
  && ok "ledger: devin still received task + note together" || bad "ledger: captured prompt lost the task or the note"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
