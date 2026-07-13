#!/usr/bin/env bash
# S-phase round-2 fixes: :free disclosure on a comma-joined model pair, and _or_run_cost returning
# exact cost ONLY when every generation ID resolves (else empty -> caller uses the labeled estimate).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN="$HERE/../outsourcerer.sh"
[ -f "$MAIN" ] || { echo "FAIL: main not found" >&2; exit 1; }

TMP="$(mktemp "${TMPDIR:-/tmp}/osrc_cd.XXXXXX")"
trap 'rm -f "$TMP" "${LOG:-}"' EXIT
sed '/^[[:space:]]*main "\$@"[[:space:]]*$/d' "$MAIN" > "$TMP"
# shellcheck disable=SC1090
set +e; source "$TMP"; set -e

fail=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1 -> '$2'"; else echo "FAIL: $1 -> '$2' (want '$3')"; fail=1; fi; }

# --- 1. :free disclosure. The live pattern (line ~2297) must match :free ANYWHERE, so a comma-joined
#        pair whose FIRST model is :free is still flagged may-train. Test the live pattern + the code. ---
freeck() { case "$1" in *:free*) echo may-train ;; *) echo paid ;; esac; }
ck "pair hy3:free,deepseek"  "$(freeck 'tencent/hy3:free,deepseek/deepseek-v4-pro')" may-train
ck "single hy3:free"         "$(freeck 'tencent/hy3:free')"                          may-train
ck "pair non-free"           "$(freeck 'z-ai/glm-5.2,deepseek/deepseek-v4-pro')"     paid
# guard against a revert to the ends-with pattern:
if grep -qE 'case "\$model" in \*:free\*\)' "$MAIN"; then echo "PASS: script uses *:free* pattern"; else echo "FAIL: script no longer uses *:free* pattern"; fail=1; fi

# --- 2. _or_run_cost: exact only when ALL gen IDs resolve; a partial resolve -> empty (labeled est). ---
LOG="$(mktemp "${TMPDIR:-/tmp}/osrc_log.XXXXXX")"
printf 'gen-1-aaaa\ngen-2-bbbb\n' > "$LOG"   # two generation ids in the "stream"
_or_load_key() { return 0; }                 # bypass network/key
# BOTH resolve -> exact sum "0.030000"
_or_gen_cost() { case "$1" in gen-1-aaaa) echo 0.01 ;; gen-2-bbbb) echo 0.02 ;; esac; }
ck "all-resolve -> exact sum" "$(_or_run_cost "$LOG")" "0.030000"
# ONE misses -> empty (so caller falls to the '~' estimate), NOT a partial 0.01
_or_gen_cost() { case "$1" in gen-1-aaaa) echo 0.01 ;; gen-2-bbbb) echo "" ;; esac; }
ck "partial-resolve -> empty" "$(_or_run_cost "$LOG")" ""

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL" >&2; exit 1; fi
echo "RESULT: PASS (all cost/disclosure checks passed)"
