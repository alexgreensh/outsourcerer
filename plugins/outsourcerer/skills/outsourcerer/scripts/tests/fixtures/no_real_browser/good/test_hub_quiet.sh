#!/usr/bin/env bash
# Synthetic: allowed shapes (no browser), so the guard does not over-match.
OSRC_HOME="$OSRC_HOME" bash "$SRC" hub serve --port "$PORT" --no-open >"$TMP/serve.log" 2>&1 &
ls "/Applications/Google Chrome.app/Contents/MacOS/" 2>/dev/null
# open "http://example" is fine inside a comment
