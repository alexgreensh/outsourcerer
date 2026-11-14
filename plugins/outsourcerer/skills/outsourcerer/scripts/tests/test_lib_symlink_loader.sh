#!/usr/bin/env bash
# test_lib_symlink_loader.sh: the lib/ modules (watchdog.sh, parity.sh) must load when outsourcerer.sh
# is reached through a symlink (a PATH launcher), both executed and sourced. SCRIPT_DIR is the
# symlink's dir, so the first loader line finds no lib/; the second (real-path) loader line must.
# A miss here is silent in production: the function is just undefined at first use.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
TMP="$(mktemp -d)" || exit 1; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
export OSRC_HOME="$TMP/state" HOME="$TMP/home" OSRC_HEARTBEAT_DISABLED=1
mkdir -p "$HOME" "$TMP/bin" "$TMP/work"
ln -s "$SRC" "$TMP/bin/outsourcerer"

# 1. Executed through the symlink: a command whose body lives in lib/parity.sh.
( cd "$TMP/work" && "$TMP/bin/outsourcerer" parity-cursor >/dev/null 2>"$TMP/err" )
if grep -q 'OUTSOURCERER:INSOURCE' "$TMP/work/AGENTS.md" 2>/dev/null; then ok "executed via symlink: parity-cursor (lib/parity.sh) wrote its block"
else bad "executed via symlink: lib/parity.sh not loaded ($(head -c 200 "$TMP/err"))"; fi

# 2. Sourced through the symlink: every moved function must be defined.
out="$(OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1; for f in _supervise _delegate_has_model_output _insource_write _insource_block parity_codex parity_droid parity_cursor; do type "$f" >/dev/null 2>&1 || echo "MISSING $f"; done' _ "$TMP/bin/outsourcerer")"
[ -z "$out" ] && ok "sourced via symlink: all lib functions defined" || bad "sourced via symlink: $out"

# 3. Sourced by real path (how the unit tests load it).
out="$(OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1; type _supervise >/dev/null 2>&1 || echo MISSING' _ "$SRC")"
[ -z "$out" ] && ok "sourced by real path: _supervise defined" || bad "sourced by real path: $out"

# 4. Defined exactly once (a double load would mean both loader lines ran for one dir).
n="$(grep -c '^_supervise()' "$SRC" "$HERE/../lib/watchdog.sh" | awk -F: '{s+=$2} END{print s}')"
[ "$n" = "1" ] && ok "_supervise has exactly one definition" || bad "_supervise defined $n times"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
