#!/bin/bash
# Keep fixture paths identical to paths resolved by the product on macOS.
TMPDIR="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || {
  printf '%s\n' 'FAIL: cannot resolve scratch base' >&2
  exit 1
}
export TMPDIR
