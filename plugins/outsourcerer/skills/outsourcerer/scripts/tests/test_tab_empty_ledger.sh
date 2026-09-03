#!/usr/bin/env bash
# test_tab_empty_ledger.sh — `tab` on an empty-but-existing ledger prints the empty-Tab line, never crashes.
#
# Issue #21 follow-up: `grep -c` prints "0" AND exits 1 on no match, so `count="$(grep -c ... || echo 0)"`
# yields "0\n0" and the arithmetic that follows dies with "0\n0: arithmetic syntax error". The
# `[ -f ledger ]` guard does not help: the file exists, it is just zero length, which is the normal
# state between install and the first recorded run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# 1. missing ledger: empty-Tab message (already worked; keep it that way)
out="$(OSRC_HOME="$TMP" HOME="$TMP" bash "$SRC" tab 2>&1)"; rc=$?
case "$out" in *"The Tab is empty"*) ok "missing ledger prints the empty-Tab message" ;; *) bad "missing ledger: $out" ;; esac

# 2. empty-but-existing ledger: the reported crash
: > "$TMP/ledger.jsonl"
out="$(OSRC_HOME="$TMP" HOME="$TMP" bash "$SRC" tab 2>&1)"; rc=$?
case "$out" in *"arithmetic syntax error"*|*"syntax error in expression"*) bad "zero-length ledger still crashes tab: $out" ;; *) ok "zero-length ledger does not crash tab" ;; esac
case "$out" in *"The Tab is empty"*) ok "zero-length ledger prints the empty-Tab message" ;; *) bad "zero-length ledger did not print the empty-Tab message: $out" ;; esac
[ "$rc" -eq 0 ] && ok "tab exits 0 on an empty ledger" || bad "tab exited $rc on an empty ledger"

# 3. whitespace-only ledger (a stray newline) behaves the same
printf '\n\n' > "$TMP/ledger.jsonl"
out="$(OSRC_HOME="$TMP" HOME="$TMP" bash "$SRC" tab 2>&1)"
case "$out" in *"The Tab is empty"*) ok "whitespace-only ledger is an empty Tab" ;; *) bad "whitespace-only ledger: $out" ;; esac

# 4. one real row still tabulates (the fix must not hide a populated Tab)
printf '{"ts":"2026-09-03T00:00:00Z","provider":"antigravity-agy","lane":"gm","model":"gemini-3.8-flash","verb":"run","cost_usd":"0.000000"}\n' > "$TMP/ledger.jsonl"
out="$(OSRC_HOME="$TMP" HOME="$TMP" bash "$SRC" tab 2>&1)"
case "$out" in *"runs recorded          : 1"*) ok "a populated ledger still tabulates (1 run)" ;; *) bad "populated ledger output wrong: $out" ;; esac
case "$out" in *Antigravity*) ok "the subscription lane is still attributed" ;; *) bad "lane attribution missing" ;; esac

# 5. class guard: no `grep -c ... || echo 0` survives in CODE (comment lines blanked first)
TAB="$(printf '\t')"
if LC_ALL=C sed -E "s/^[ $TAB]*#.*\$//" "$SRC" | LC_ALL=C grep -nE 'grep -c[^|]*[|][|] echo 0' | grep -q .; then
  bad "a 'grep -c ... || echo 0' pattern survives (prints 0 twice on no match)"
else ok "no 'grep -c ... || echo 0' pattern left in the source"; fi

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
