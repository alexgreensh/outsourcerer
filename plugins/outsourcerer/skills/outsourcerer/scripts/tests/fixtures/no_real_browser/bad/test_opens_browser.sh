#!/usr/bin/env bash
# Synthetic: the browser-open shapes a test must never use (each line is one violation).
open "http://127.0.0.1:8790/?t=$TOK"
python3 -c 'import webbrowser; webbrowser.open("http://127.0.0.1:1")'
OSRC_HOME="$OSRC_HOME" bash "$SRC" hub serve --port "$PORT" >"$TMP/serve.log" 2>&1 &
