#!/usr/bin/env bash
set -uo pipefail
D="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/p56.XXXXXX")"; trap 'rm -rf "$T"' EXIT
export OSRC_HOME="$T/home" OSRC_HEARTBEAT_DISABLED=1 OSRC_SOURCED=1
mkdir -p "$OSRC_HOME"
OSRC_FAILOVER_LANES='opencode or'
. "$D/outsourcerer.sh" >/dev/null 2>&1
pass=0; fail=0
check() { if "$@"; then echo "PASS: $*"; pass=$((pass+1)); else echo "FAIL: $*"; fail=$((fail+1)); fi; }
not_contains() { case " $1 " in *" $2 "*) return 1 ;; *) return 0 ;; esac; }
check not_contains "$OSRC_FAILOVER_LANES" opencode
check test "$(osrc_lane_billing opencode opencode-go/glm-5.3-flash)" = metered
check test "$(osrc_lane_billing opencode opencode/model)" = metered
check test "$(osrc_lane_billing opencode glm-5.3-flash)" = metered
check test "$(osrc_lane_billing opencode)" = metered
check bash -c 'case "$1" in *opencode*metered*) exit 0;; *) exit 1;; esac' _ "$(osrc_lane_limits)"
ln -s "$D/outsourcerer.sh" "$T/osrc"
check bash -c 'export OSRC_SOURCED=1; . "$1" >/dev/null 2>&1; type lane_descriptor_opencode >/dev/null' _ "$T/osrc"
# Exercise the interactive decision logic without requiring a pseudo-terminal.
_tty_gate() (
  [() { if test "${1:-}" = -t; then return 0; fi; builtin [ "$@"; }
  unset OSRC_SPEND_OK
  _osrc_spend_gate opencode opencode/model opencode test >/dev/null 2>&1
)
printf 'y\n' | _tty_gate; yes_rc=$?
printf 'n\n' | _tty_gate; no_rc=$?
check test "$yes_rc" = 0
check test "$no_rc" != 0
mkdir -p "$T/copy"
cp "$D/outsourcerer.sh" "$T/copy/outsourcerer.sh"
cp -R "$D/lib" "$T/copy/lib"
rm "$T/copy/lib/lane-opencode.sh"
unset OSRC_SOURCED
out="$(OSRC_DOCTOR_OFFLINE=1 "$T/copy/outsourcerer.sh" doctor 2>&1)"; rc=$?
check test "$rc" = 0
if printf '%s' "$out" | grep -q "_doctor_opencode: command not found"; then echo "FAIL: missing module doctor"; fail=$((fail+1)); else echo "PASS: missing module doctor"; pass=$((pass+1)); fi
mkdir -p "$T/bin"
printf '#!/bin/sh\ncase "$1" in --version) echo 2.2.6;; auth) echo "OpenCode Go api";; run|--standalone) touch "%s/dispatched";; esac\n' "$T" > "$T/bin/opencode"
chmod +x "$T/bin/opencode"
PATH="$T/bin:$PATH" OSRC_OPENCODE_ALLOW_NONGO=1 OSRC_SPEND_OK=1 OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$D/outsourcerer.sh" --provider opencode run -m opencode/paid x > "$T/refusal" 2>&1; rc=$?
check test "$rc" != 0
check test ! -e "$T/dispatched"
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
