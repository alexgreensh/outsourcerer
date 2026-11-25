#!/usr/bin/env bash
# Redirect order: bash applies redirections left to right, so in `read x < "$f" 2>/dev/null` the
# missing-file error is printed BEFORE stderr is silenced. The user then sees "No such file or
# directory" on an ordinary path (it showed on every session start). Silence first: `2>/dev/null < "$f"`.
cd "$(dirname "$0")/.." || exit 1
pass=0; fail=0
hits="$(grep -n -E '(read|cat|jq|head|grep)[^|;&]* < *"[^"]*" 2>/dev/null' outsourcerer.sh lib/*.sh 2>/dev/null)"
if [ -z "$hits" ]; then echo "PASS: no input redirect comes before its 2>/dev/null"; pass=$((pass+1))
else printf 'FAIL: input redirect before 2>/dev/null (the error still prints):\n%s\n' "$hits"; fail=$((fail+1)); fi
d="$(mktemp -d)"; out="$( { IFS= read -r x 2>/dev/null < "$d/missing"; } 2>&1 )"; rm -rf "$d"
if [ -z "$out" ]; then echo "PASS: the fixed order is silent on a missing file"; pass=$((pass+1))
else echo "FAIL: fixed order still printed: $out"; fail=$((fail+1)); fi
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
