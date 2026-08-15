#!/usr/bin/env bash
# test_second_opinion_agree.sh — _so_agree semantic-agreement gate for `second-opinion`.
# Guards the two silent false-agree paths: contradiction (negation flip) and superset.
# The invariant: a false reading only ever ESCALATES (never a wrong agreement).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# chk <desc> <agree|disagree> <answer1> <answer2>  — drives the built-in __so-agree hook.
chk() {
  printf '%s' "$3" > "$T/a"; printf '%s' "$4" > "$T/b"
  local got; got="$(OSRC_LEDGER_QUIET=1 bash "$SRC" __so-agree "$T/a" "$T/b" 2>/dev/null)"
  [ "$got" = "$2" ] && ok "$1 -> $got" || bad "$1 (got '$got', want '$2')"
}

# --- Must ESCALATE (disagree) — the unsafe false-agree cases ---
chk "contraction negation (can vs can't)" disagree "You can deploy this."      "You can't deploy this."
chk "word negation (do vs do not)"        disagree "Delete the file."           "Do not delete the file."
chk "never-flip"                          disagree "Always retry on error."      "Never retry on error."
chk "superset adds material content"      disagree "delete the file"             "delete the file and the backup and the logs"
chk "qualified yes vs bare yes"           disagree "yes"                          "yes but only in staging"
chk "numeric conflict"                    disagree "set the timeout to 30 seconds" "set the timeout to 60 seconds"

# --- Must AGREE — same answer, differently worded (savings preserved) ---
chk "formatting/verbosity only"           agree    "Use **30** retries, then stop." "use 30 retries then stop"
chk "token reorder"                       agree    "stop after 30 retries"        "after 30 retries stop"
chk "byte-identical after normalize"      agree    "Yes."                         "yes"

# --- Safety-bias sanity: an empty answer is "can't tell" -> escalate ---
chk "empty vs nonempty escalates"         disagree ""                            "some answer"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
