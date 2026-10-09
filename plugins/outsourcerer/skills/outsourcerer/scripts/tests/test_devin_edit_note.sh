#!/usr/bin/env bash
# test_devin_edit_note.sh — a devin `edit` (accept-edits) prompt tells the delegate up front that a
# command needing confirmation ends the run, so it finishes its edits and hands verification back.
#
# Why: devin -p in accept-edits refuses any exec it wants confirmed and ends the session (3000.11
# prints "rejected a tool call that requires confirmation" and exits 0). In practice that is the
# delegate's own test/build step after its edits, so the job stops right where it would verify.
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

# Each dispatch runs in a fresh shell with the script sourced (OSRC_SOURCED=1 skips main).
prompt_for() { # <perm> [env...]
  local perm="$1"; shift
  local cap="$FAKE_ROOT/prompt.$perm.$#"
  env DEVIN_CAPTURE="$cap" "$@" bash -c 'f="$1"; perm="$2"; set --; OSRC_SOURCED=1; . "$f" >/dev/null 2>&1; PROVIDER=devin; delegate "$perm" "" -m swe-2 "fix the parser"' _ "$SRC" "$perm" >/dev/null 2>&1
  cat "$cap" 2>/dev/null
}

p="$(prompt_for accept-edits)"
printf '%s' "$p" | grep -q 'fix the parser' \
  && ok "edit prompt still carries the task" || bad "edit prompt lost the task: $p"
printf '%s' "$p" | grep -q 'refused and ends the run' \
  && ok "edit prompt warns that a confirmation-needing command ends the run" \
  || bad "edit prompt has no confirmation note"
printf '%s' "$p" | grep -q 'end your reply with the exact verification commands' \
  && ok "edit prompt hands verification back to the orchestrator" \
  || bad "edit prompt does not ask for the verification commands"

p="$(prompt_for auto)"
printf '%s' "$p" | grep -q 'fix the parser' && ok "read-only (auto) prompt still dispatches the task" || bad "read-only (auto) prompt was not captured"
printf '%s' "$p" | grep -q 'refused and ends the run' \
  && bad "read-only (auto) prompt got the edit note" \
  || ok "read-only (auto) prompt is unchanged"

p="$(prompt_for accept-edits OSRC_DEVIN_EDIT_NOTE=0)"
printf '%s' "$p" | grep -q 'fix the parser' || bad "opt-out edit prompt was not captured"
printf '%s' "$p" | grep -q 'refused and ends the run' \
  && bad "OSRC_DEVIN_EDIT_NOTE=0 did not remove the note" \
  || ok "OSRC_DEVIN_EDIT_NOTE=0 leaves the edit prompt untouched"

# The note keys on the perm string, so pin the verb -> perm mapping it depends on.
grep -qE '^[[:space:]]+edit\)[[:space:]]+route_delegate "accept-edits"' "$SRC" \
  && ok "the edit verb dispatches with accept-edits (the perm the note keys on)" \
  || bad "the edit verb no longer dispatches with accept-edits; the note would silently stop attaching"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
