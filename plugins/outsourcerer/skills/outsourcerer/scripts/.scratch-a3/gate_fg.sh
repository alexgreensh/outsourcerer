#!/usr/bin/env bash
# gate_fg.sh: mimic conformance.sh's real shape — bounded runner in the FOREGROUND.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
have() { command -v "$1" >/dev/null 2>&1; }
. "$D/runner_extract.sh"
OSRC_SUITE_TIMEOUT=60 _run_unit_suite_bounded "$1"
echo "runner_rc=$_suite_rc timed_out=$_suite_timed_out" > "$D/suites/fg.rc"
