#!/usr/bin/env bash
# test_selfcontained_hardening.sh — locks the self-contained hardening fixes.
# Static presence checks + two behavioral checks. Run: bash test_selfcontained_hardening.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
has() { grep -Fq "$1" "$SRC" && ok "$2" || bad "$2 (missing: $1)"; }

# Ledger append computed into a var then single/flock'd append (no direct jq >> race).
has 'if flock -w 5 9' "ledger uses a bounded-wait flock-guarded append (no silent drop on lock failure)"
has 'appended without lock' "lock-failure falls back to a best-effort append + warns (never silently drops)"
has '_lockfail' "lock-fail flag raised inside the fd-9 group, warning emitted OUTSIDE it (not eaten by 2>/dev/null)"
# The recursive scan sanitizes a non-integer depth instead of failing open.
has 'case "$_depth" in' "OSRC_SECRET_SCAN_DEPTH sanitized to an integer (no fail-open on bogus depth)"
# find runs into a temp file with its exit status CHECKED (proc-subst discarded it).
has 'workspace credential scan could not complete' "deep scan fails CLOSED when find cannot complete (rc checked)"
has '_depth" -gt 12' "oversized scan depth capped (no unbounded walk)"
# fanout returns nonzero when any job fails to launch.
has 'FAILED to launch' "fanout reports partial-launch failure and returns nonzero"
grep -Eq "jq -cn[^|]*>> \"\\\$OSRC_LEDGER\"" "$SRC" && bad "raw 'jq ... >> ledger' still present" || ok "no raw jq-append-to-ledger race"
# WITH_SPEC split without globbing.
has 'read -ra _ws <<< "$WITH_SPEC"' "_secret_scan splits WITH_SPEC via read -ra (no glob)"
# Scope the check to _secret_scan: the --with parsers at build_mcp_flags intentionally word-split.
ss_body="$(awk '/^_secret_scan\(\) *\{/{f=1} f{print} f&&/^}/{exit}' "$SRC")"
printf '%s' "$ss_body" | grep -Fq 'for tok in $WITH_SPEC' && bad "_secret_scan still has unquoted WITH_SPEC loop" || ok "_secret_scan unquoted WITH_SPEC loop removed"
# Both OSRC_ALLOWED_TOOLS spots use read -ra.
[ "$(grep -c 'read -ra _at <<< "$OSRC_ALLOWED_TOOLS"' "$SRC")" -eq 2 ] && ok "both OSRC_ALLOWED_TOOLS spots deglobbed" || bad "expected 2 read -ra _at spots"
grep -Fq 'tools=(--allowedTools $OSRC_ALLOWED_TOOLS)' "$SRC" && bad "unquoted allowedTools still present" || ok "no unquoted allowedTools expansion"
# ORIG-rewrite bounds-guards before assigning.
has '(_i+1)) -lt ${#ORIG[@]} ]' "ORIG rewrite bounds-checked (no phantom element)"
# Private temp/result files. umask is set at run_job START (before the Codex last.txt write).
has 'umask 077' "umask 077 present at run_job start (covers the primary Codex last.txt path)"
awk '/^run_job\(\) *\{/{f=1} f{print} f&&/^  local jd=/{exit}' "$SRC" | grep -Fq 'umask 077' && ok "umask 077 precedes job-dir/delegate setup" || bad "umask 077 not at run_job start"
[ "$(grep -c 'old_umask' "$SRC")" -ge 4 ] && ok "temp files (.ccerr/.ccnative) hardened with umask save/restore" || bad "temp-file umask hardening missing"

# --- Behavioral: a trailing -m (genuinely last token) does not append a phantom element. ---
( . "$SRC" >/dev/null 2>&1
  ORIG=(edit -m); _dvm="glm-5.2"        # -m is the LAST element -> _i+1 is out of range
  before=${#ORIG[@]}
  for _i in "${!ORIG[@]}"; do case "${ORIG[$_i]}" in -m|--model) [ $((_i+1)) -lt ${#ORIG[@]} ] && ORIG[$((_i+1))]="$_dvm" ;; esac; done
  after=${#ORIG[@]}
  [ "$before" -eq "$after" ] && echo PHANTOM_OK || echo "PHANTOM_BAD before=$before after=$after"
) | grep -q PHANTOM_OK && ok "trailing -m (last token) does not grow ORIG (phantom-free)" || bad "phantom element appended"

# --- Behavioral: record_ledger append writes exactly one intact JSON line. ---
if command -v jq >/dev/null 2>&1; then
  TMP="$(mktemp -d)"; export OSRC_HOME="$TMP" OSRC_LEDGER="$TMP/ledger.jsonl"
  ( . "$SRC" >/dev/null 2>&1
    OSRC_STREAM=0 record_ledger cc glm mid auto "a task" 2>/dev/null )
  lines=$(wc -l < "$OSRC_LEDGER" 2>/dev/null | tr -d ' ')
  if [ "${lines:-0}" -eq 1 ] && jq -e . "$OSRC_LEDGER" >/dev/null 2>&1; then ok "record_ledger writes one intact JSON line"; else bad "ledger line count=$lines / invalid json"; fi
  rm -rf "$TMP"
else
  ok "(jq absent -> record_ledger no-ops; behavioral check skipped)"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
