#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$HERE/test_shell_scratch.py"
