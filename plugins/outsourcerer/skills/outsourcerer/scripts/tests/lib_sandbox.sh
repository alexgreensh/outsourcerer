#!/usr/bin/env bash
# Isolate state and replace delegate executables before loading the CLI.
osrc_test_sandbox() {
  local T vehicle
  T="$(mktemp -d "${TMPDIR:-/tmp}/osrc-test.XXXXXX")" || return 1
  export OSRC_TEST_ROOT="$T" HOME="$T/h" OSRC_HOME="$T/o"
  OSRC_SOURCED=1; export -n OSRC_SOURCED
  trap 'rm -rf "$OSRC_TEST_ROOT"' EXIT
  mkdir -p "$HOME" "$OSRC_HOME" "$T/bin" || return 1
  for vehicle in claude devin codex agy droid; do
    cat > "$T/bin/$vehicle" <<'STUB' || return 1
#!/bin/sh
printf '%s\n' "$0 $*" >> "$OSRC_TEST_ROOT/stub.log"
STUB
    chmod +x "$T/bin/$vehicle" || return 1
  done
  export PATH="$T/bin:$PATH"
}
