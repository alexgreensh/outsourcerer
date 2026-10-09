#!/usr/bin/env bash
# Regression for the trap-then-source leak (sessions/2026-10-09-pr-sweep/tasks/b-round3.md).
# A caller that arms `trap 'rm -rf "$fixture"' EXIT` before sourcing outsourcerer.sh must
# not lose its cleanup to the engine's own EXIT trap, which is installed at source time.
# Required chain semantics:
#   - the engine's own cleanup still runs (with-mcp/hdr temp files removed),
#   - then the caller's handler runs, exactly once,
#   - and the script exits with the status it was already exiting with.
# A function that saves/restores the EXIT trap (the obligation guard) must leave the
# chained handler in place, and a re-source must not wrap the chain in itself.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${OSRC_TEST_SRC:-$HERE/../outsourcerer.sh}"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

BASE="$(mktemp -d "${TMPDIR:-/tmp}/test-exit-chain.XXXXXX")"
trap 'rm -rf "$BASE"' EXIT

# Spawn a fresh bash that sandboxes HOME/OSRC_HOME, optionally arms a caller-style
# cleanup trap, sources the engine, optionally exercises a save/restore function,
# touches a with-mcp temp named for its own $$ (proof the engine cleanup ran or not),
# and exits with the requested status. Args: <scenario> <sandbox-dir> [exit-status]
run_child() {
  local scen="$1" sb="$2" rc="${3:-0}"
  mkdir -p "$sb/fx" "$sb/home"
  env HOME="$sb" OSRC_HOME="$sb/home" OSRC_SOURCED=1 bash -c '
    scen="$1"; sb="$2"; rc="$3"; src="$4"
    set --
    case "$scen" in
      bare) ;;
      rcsave) trap "rc=\$?; echo \"saw=\$rc\" >> \"$sb/saw\"; exit \$rc" EXIT ;;
      *)    trap "rm -rf \"$sb/fx\"; echo fired >> \"$sb/count\"" EXIT ;;
    esac
    . "$src" >/dev/null 2>&1
    touch "$OSRC_HOME/with-mcp-$$.json"
    case "$scen" in
      save)     _obligation_guard_begin oid sid; _obligation_guard_end ;;
      resource) . "$src" >/dev/null 2>&1 ;;
    esac
    exit "$rc"
  ' _ "$scen" "$sb" "$rc" "$SRC"
}

fx_gone()  { [ ! -d "$1/fx" ]; }
mcp_gone() { ! ls "$1/home/"with-mcp-*.json >/dev/null 2>&1; }
count_is() { [ -f "$1/count" ] && [ "$(wc -l < "$1/count" | tr -d ' ')" = "$2" ]; }

# --- (a) caller trap + exit 0: fixture gone, engine cleanup ran, handler once ------
SB="$BASE/a"; run_child chain "$SB" 0; rc=$?
[ "$rc" -eq 0 ] && ok "chain: exit 0 preserved" || bad "chain: rc=$rc want 0"
fx_gone "$SB" && ok "chain: caller's rm -rf fixture fired" || bad "chain: fixture leaked at $SB/fx"
mcp_gone "$SB" && ok "chain: engine cleanup still ran (with-mcp file removed)" || bad "chain: engine cleanup lost"
count_is "$SB" 1 && ok "chain: caller handler ran exactly once" || bad "chain: handler count '$(cat "$SB/count" 2>/dev/null | wc -l | tr -d " ")'"

# --- (b) caller trap + exit 3: status survives both halves -------------------------
SB="$BASE/b"; run_child chain "$SB" 3; rc=$?
[ "$rc" -eq 3 ] && ok "chain: exit 3 preserved through the chain" || bad "chain: rc=$rc want 3"
fx_gone "$SB" && ok "chain+rc3: fixture still removed" || bad "chain+rc3: fixture leaked"

# --- (c) no prior trap: engine cleanup behaves exactly as before -------------------
SB="$BASE/c"; run_child bare "$SB" 0; rc=$?
[ "$rc" -eq 0 ] && ok "bare: exit 0" || bad "bare: rc=$rc"
mcp_gone "$SB" && ok "bare: engine cleanup runs unchanged with no caller trap" || bad "bare: with-mcp file leaked"
[ ! -f "$SB/count" ] && ok "bare: nothing phantom-fired without a caller trap" || bad "bare: count file appeared"

# --- (d) a save/restore function leaves the chain armed ----------------------------
SB="$BASE/d"; run_child save "$SB" 0; rc=$?
fx_gone "$SB" && ok "save/restore: caller handler survives the obligation guard" || bad "save/restore: fixture leaked after guard end"
mcp_gone "$SB" && ok "save/restore: engine cleanup still runs after guard end" || bad "save/restore: engine cleanup lost"

# --- (e) re-sourcing must not wrap the chain in itself -----------------------------
SB="$BASE/e"; run_child resource "$SB" 0; rc=$?
[ "$rc" -eq 0 ] && ok "re-source: exits normally (no self-recursive chain)" || bad "re-source: rc=$rc"
fx_gone "$SB" && ok "re-source: caller handler still fires once" || bad "re-source: fixture leaked"
count_is "$SB" 1 && ok "re-source: handler ran exactly once" || bad "re-source: handler fired '$(wc -l < "$SB/count" 2>/dev/null | tr -d " ")' times"

# --- (f) a caller handler that reads $? must see the PENDING status --------------
# The engine cleanup's own last-command status must not leak into the caller's view:
# with `trap 'rc=$?; ...; exit $rc'` a failing script must stay failing.
SB="$BASE/f"; run_child rcsave "$SB" 3; rc=$?
[ "$rc" -eq 3 ] && ok "rcsave: exit 3 survives a handler that exits with \$?" || bad "rcsave: rc=$rc want 3"
[ "$(cat "$SB/saw" 2>/dev/null)" = "saw=3" ] && ok "rcsave: handler read \$? = 3 (pending, not engine cleanup's)" || bad "rcsave: handler saw '$(cat "$SB/saw" 2>/dev/null)' want saw=3"

# --- (g) same handler shape, exit 0: unchanged -----------------------------------
SB="$BASE/g"; run_child rcsave "$SB" 0; rc=$?
[ "$rc" -eq 0 ] && ok "rcsave: exit 0 unchanged" || bad "rcsave: rc=$rc want 0"
[ "$(cat "$SB/saw" 2>/dev/null)" = "saw=0" ] && ok "rcsave: handler read \$? = 0" || bad "rcsave: saw '$(cat "$SB/saw" 2>/dev/null)' want saw=0"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
