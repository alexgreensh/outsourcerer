#!/usr/bin/env bash
# test_marker_forgery.sh — the prompt must never contain a line that, echoed back, is a valid status.
#
# Terminal markers are the control plane: OSRC::DONE#<mark> decides whether a job is believed to have
# finished. The per-run mark defeats an ACCIDENTAL echo of the generic protocol, because the id is
# minted per run and cannot be guessed. But the injected protocol block used to print its EXAMPLE
# lines carrying the LIVE id — so a delegate that quoted the block back at the end of its output
# emitted a perfectly valid signed terminal by accident, and the supervisor believed it. Cheap models
# resist injection poorly and quote their instructions constantly, so this was reachable by accident,
# not just by malice.
#
# The fix is to make the prompt contain no copyable valid marker at all: the live id is disclosed once
# as prose, and every example uses the literal placeholder <run-id>.
#
# The rejected alternative is recorded here because it looks correct and is not: requiring the terminal
# to be the FINAL non-blank line. Real output frequently ends with a footer (the loop prints its own
# spend summary after the delegate's DONE), so that rule silently stops recognising genuine terminals.
# Test D pins that regression down permanently.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

export OSRC_MARK='deadbeef'
. "$SRC" >/dev/null 2>&1

# A test that silently does not load the functions reports success by returning empty strings, which
# is exactly the kind of green that means nothing. Refuse to continue unless they are really here.
type -t osrc_protocol_block >/dev/null || { echo "FAIL: osrc_protocol_block not loaded"; exit 1; }
type -t _last_marker        >/dev/null || { echo "FAIL: _last_marker not loaded"; exit 1; }

osrc_protocol_block > "$TMP/block.txt"

# --- the prompt itself must not contain a valid signed marker ---
if grep -qE "OSRC::(DONE|BLOCKED|NEED_INPUT|PROGRESS)#${OSRC_MARK}" "$TMP/block.txt"; then
  bad "the injected protocol block still prints an example carrying the LIVE run id"
else
  ok "no line in the injected prompt is a valid signed marker (examples use <run-id>)"
fi

# --- echoing the real block back must not be read as a terminal ---
r="$(_last_marker "$TMP/block.txt")"
[ -z "$r" ] && ok "a delegate echoing the protocol block verbatim mints no terminal" \
            || bad "echoing the block produced a terminal marker [$r]"

# --- but a genuine signed terminal must still register ---
{ cat "$TMP/block.txt"; printf 'OSRC::DONE#%s real work done\n' "$OSRC_MARK"; } > "$TMP/genuine.txt"
r="$(_last_marker "$TMP/genuine.txt")"
[ "$r" = "OSRC::DONE" ] && ok "a genuine signed terminal is still recognised" \
                        || bad "genuine signed terminal was not recognised (got [$r])"

# --- and must survive trailing output after it (the rejected final-line rule would break this) ---
{ printf 'OSRC::DONE#%s done\n' "$OSRC_MARK"; printf '>>> [outsourcerer] used 1 attempt over 0m30s\n'; } > "$TMP/foot.txt"
r="$(_last_marker "$TMP/foot.txt")"
[ "$r" = "OSRC::DONE" ] && ok "a terminal followed by a footer line is still recognised" \
                        || bad "a footer after the terminal blinded detection (final-line regression)"

# --- the placeholder itself must never be mistaken for a real marker ---
printf 'OSRC::DONE#<run-id> summary\n' > "$TMP/ph.txt"
r="$(_last_marker "$TMP/ph.txt")"
[ -z "$r" ] && ok "the literal <run-id> placeholder is not a terminal" \
            || bad "the placeholder example itself registered as a terminal [$r]"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
