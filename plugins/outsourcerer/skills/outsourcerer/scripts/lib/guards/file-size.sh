#!/usr/bin/env bash
# file-size: the repo's own 1,000-line ratchet (scripts/check_file_size.py), taken from the base ref.
# Checks committed changes since the merge-base; a repo without the script passes.
set -u
git cat-file -e "$OSRC_GUARD_BASE_REF:scripts/check_file_size.py" 2>/dev/null || exit 0
git show "$OSRC_GUARD_BASE_REF:scripts/check_file_size.py" >"$OSRC_GUARD_TMP/check_file_size.py" || exit 0
out="$(python3 -I "$OSRC_GUARD_TMP/check_file_size.py" --base "$OSRC_GUARD_BASE" 2>&1)" && exit 0
sed -n 's/^FILE-SIZE FAIL: */WHAT: /p' <<<"$out"
echo "FIX: move the new code into a new module file; a file already over the limit may only shrink"
exit 1
