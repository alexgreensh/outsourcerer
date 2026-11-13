#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_sandbox.sh"
osrc_test_sandbox
# test_tap_statusline.sh — the statusline command a versioned plugin-cache install emits must
# resolve the NEWEST installed version at render time, so it survives a plugin update+prune that
# deletes the version it was pinned to. And it must never embed a path it cannot safely single-quote
# into the `sh -c` payload (the guard falls through to the plain pinned command instead).
#
# Guards the change from PR #26. The function had no coverage before this suite.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp -d "$PWD/.test-tapstatus.XXXXXX")"
trap 'rm -rf "$TMP"; rm -rf "$OSRC_TEST_ROOT"' EXIT

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

set --
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
type -t _tap_statusline_cmd >/dev/null || { echo "FAIL: _tap_statusline_cmd not loaded"; exit 1; }

OSRC_PLATFORM=linux   # force the non-windows branch deterministically on any runner

# A realistic versioned plugin-cache tree: .../cache/<plugin>/<name>/<version>/skills/.../outsourcerer.sh
BASE="$TMP/plugins/cache/outsourcerer/outsourcerer"
for v in 0.11.1 0.12.1 0.12.10; do
  mkdir -p "$BASE/$v/skills/outsourcerer/scripts"
  printf '#!/bin/sh\n[ "$1" = tap ] && echo "TAP-v%s"\n' "$v" > "$BASE/$v/skills/outsourcerer/scripts/outsourcerer.sh"
  chmod +x "$BASE/$v/skills/outsourcerer/scripts/outsourcerer.sh"
done

# 1) a non-cache install path emits the plain pinned command, no resolver
SCRIPT_PATH="/usr/local/bin/outsourcerer.sh"
out="$(_tap_statusline_cmd)"
[ "$out" = "/usr/local/bin/outsourcerer.sh tap run" ] && ok "non-cache path emits the plain pinned command" || bad "non-cache path emitted: $out"

# 2) a versioned cache path emits an sh -c resolver that keeps a fallback to the pinned path
SCRIPT_PATH="$BASE/0.11.1/skills/outsourcerer/scripts/outsourcerer.sh"
out="$(_tap_statusline_cmd)"
case "$out" in "sh -c "*) ok "versioned cache path emits an sh -c resolver" ;; *) bad "expected sh -c resolver, got: $out" ;; esac
case "$out" in *'${s:-'*) ok "resolver keeps a fallback to the pinned path" ;; *) bad "resolver has no fallback: $out" ;; esac

# 3) the emitted resolver runs the NEWEST version (version-sorted), not the pinned old one
ran="$(eval "$out" 2>/dev/null)"
[ "$ran" = "TAP-v0.12.10" ] && ok "resolver runs the newest installed version (0.12.10, not lexical 0.12.1)" || bad "resolver ran: '$ran' (wanted TAP-v0.12.10)"

# 4) after a prune deletes the pinned version dir, the resolver still finds a survivor (the bug it fixes)
rm -rf "$BASE/0.11.1"
ran="$(eval "$out" 2>/dev/null)"
[ "$ran" = "TAP-v0.12.10" ] && ok "resolver survives deletion of the pinned version dir" || bad "post-prune resolver ran: '$ran'"

# 5) injection guard (char-class arm): a real cache tree under a dir whose name holds a '$' must
#    fall through to the plain pinned command, never into the single-quoted sh -c payload
DOLLAR="$TMP/pl\$ug/plugins/cache/outsourcerer/outsourcerer/0.12.1/skills/outsourcerer/scripts"
mkdir -p "$DOLLAR"
: > "$DOLLAR/outsourcerer.sh"
SCRIPT_PATH="$DOLLAR/outsourcerer.sh"
out="$(_tap_statusline_cmd)"
case "$out" in "sh -c "*) bad "a \$-containing path was embedded into an sh -c payload (guard bypass): $out" ;; *) ok "a \$-containing cache path falls through to the plain pinned command (guard holds)" ;; esac
case "$out" in *"tap run") ok "guard fallthrough still emits a runnable pinned command" ;; *) bad "guard fallthrough emitted a malformed command: $out" ;; esac

# 6) injection guard (empty-vroot arm): a cache-shaped path that does not exist yields empty vroot -> plain
SCRIPT_PATH="$TMP/does/not/exist/plugins/cache/x/y/0.1.0/skills/outsourcerer/scripts/outsourcerer.sh"
out="$(_tap_statusline_cmd)"
case "$out" in "sh -c "*) bad "an unresolvable cache path still emitted a resolver: $out" ;; *) ok "an unresolvable cache path (empty vroot) falls through to plain" ;; esac

cd "$TMP" 2>/dev/null || true
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
