#!/usr/bin/env bash
# test_limits_freshness.sh — a usage figure must never be reported, or routed on, as if it were current
# when it is not.
#
# Reported from real use: outsourcerer said the ChatGPT weekly window was 88% used (so 12% left) while
# the account actually had nothing left. Codex only records rate limits WHILE IT RUNS, so with no
# recent codex session the newest rollout on disk can be days old — the reading that day was 64 hours
# stale. Claude's meter already had a fail-closed freshness gate; the codex path had none.
#
# The direction of the error is what makes it dangerous. Usage only rises within a window, so a stale
# reading is a FLOOR and always OVERSTATES remaining headroom, which is precisely how work gets routed
# to a lane that is already exhausted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1

LANES=" codex=sol/terra openrouter=funded"

# A fresh, low reading is a real reason to prefer the ChatGPT lane.
r="$(_conserve_reco "claude5h=80 codex5h=10 codexwk=10" "$LANES" 2>/dev/null)"
case "$r" in *"Codex Sol/Terra"*) ok "a FRESH low reading may route grind to the ChatGPT lane" ;;
  *) bad "fresh low reading did not route to codex: $r" ;; esac

# The identical numbers, marked stale, must not.
r="$(_conserve_reco "claude5h=80 codex5h=10 codexwk=10 codexage=231017" "$LANES" 2>/dev/null)"
case "$r" in *"Codex Sol/Terra"*) bad "STALE reading still routed work to the ChatGPT lane: $r" ;;
  *) ok "the same numbers, stale, are refused for routing (fails closed)" ;; esac

# Refusing codex must not silently drop the user with nothing: another lane or an explicit statement.
case "$r" in *OpenRouter*|*"no lower-cost lane"*) ok "refusing a stale lane still yields an actionable line" ;;
  *) bad "stale refusal produced no usable guidance: $r" ;; esac

# The human-facing text must say the figure is a FLOOR and why, not just print a number. A bare
# "88% used" reads as "12% left", which is the sentence that sent work to an empty lane.
grep -q 'AT LEAST that used' "$SRC" \
  && ok "the stale figure is described as a floor, not a current value" \
  || bad "stale figures are still presented as if current"
grep -q 'Usage only rises within a window' "$SRC" \
  && ok "the message explains WHY the real number is higher" \
  || bad "no explanation of why a stale reading understates usage"
grep -q 'Run codex once to refresh' "$SRC" \
  && ok "the message gives the user a way to get a fresh reading" \
  || bad "no remedy offered for a stale reading"

# Source-level: the age must travel in the RETURN STRING. An exported variable would die in the
# command substitution the caller uses — the same defect that left the 0-writes flag dead for its
# whole life, and the reason this bug was invisible.
awk '/^_codex_rate_limits\(\)/,/^}/' "$SRC" | grep -q 'export OSRC_CODEX_READING_AGE' \
  && bad "the reading age is exported from a function read via command substitution (it will be lost)" \
  || ok "the reading age travels in the return string, not an export"

# And the threshold must be tunable rather than a magic number nobody can adjust.
grep -q 'OSRC_LIMITS_MAX_AGE' "$SRC" \
  && ok "the staleness threshold is configurable (OSRC_LIMITS_MAX_AGE)" \
  || bad "staleness threshold is hardcoded"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
