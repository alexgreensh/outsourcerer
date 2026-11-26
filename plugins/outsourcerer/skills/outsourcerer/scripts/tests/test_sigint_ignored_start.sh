#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_sigint_ignored_start.sh: the gate started with SIGINT ignored (`nohup bash conformance.sh &`
# from a script) must either restore SIGINT for its suites or SKIP the INT-trap suites with the
# reason. Never a silent FAIL or PASS.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
TMP="$(mktemp -d "${TMPDIR%/}/osrc-sigint.XXXXXX")" || exit 1; trap 'rm -rf "$TMP"' EXIT

# A probe that uses the gate's own helper, then reports whether an INT trap can install.
cat > "$TMP/probe.sh" <<PROBE
. "$HERE/lib_sigint.sh"
_osrc_sigint_restore "\$@" || { echo "still-ignored args=\$*"; exit 0; }
trap 'echo trapped' INT; echo "trap=[\$(trap -p INT)] args=\$*"
PROBE
B="${BASH:-bash}"
# A simple command run with & in a non-interactive shell starts with SIGINT ignored.
pre="$("$B" -c '"$1" -c "trap \"echo t\" INT; trap -p INT" & wait' _ "$B")"
[ "$pre" = "trap -- '' SIGINT" ] && ok "fixture: a background job starts with SIGINT ignored" || bad "fixture did not ignore SIGINT: $pre"

out="$("$B" -c '"$1" "$2" a "b c" & wait' _ "$B" "$TMP/probe.sh")"
[ "$out" = "trap=[trap -- 'echo trapped' SIGINT] args=a b c" ] \
  && ok "ignored SIGINT at start: re-exec restores it and keeps the argv" || bad "restore failed: $out"

# No python3 and no perl on PATH: the helper says it could not restore (the gate then SKIPs).
mkdir -p "$TMP/bin"; for c in bash dirname mktemp rm cat; do p="$(command -v "$c")" && ln -s "$p" "$TMP/bin/$c"; done
out="$(PATH="$TMP/bin" "$B" -c '"$1" "$2" x & wait' _ "$B" "$TMP/probe.sh")"
[ "$out" = "still-ignored args=x" ] && ok "no shim available: the helper reports SIGINT still ignored" || bad "no-shim path: $out"

out="$("$B" "$TMP/probe.sh" fg)"
[ "$out" = "trap=[trap -- 'echo trapped' SIGINT] args=fg" ] && ok "foreground start: nothing re-exec'd" || bad "foreground: $out"

# The gate wires both halves: restore at start, SKIP (with the reason) when it could not.
C="$HERE/conformance.sh"
grep -q '^\. "\$(dirname "\${BASH_SOURCE\[0\]}")/lib_sigint.sh" && _osrc_sigint_restore "\$@"' "$C" \
  && ok "conformance.sh restores SIGINT before anything else" || bad "conformance.sh does not call _osrc_sigint_restore at start"
grep -q '_INT_SKIP=' "$C" && grep -q 'SIGINT was ignored when the gate started' "$C" \
  && ok "conformance.sh SKIPs the INT-trap suites with the reason when SIGINT stays ignored" || bad "no SKIP path in conformance.sh"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
