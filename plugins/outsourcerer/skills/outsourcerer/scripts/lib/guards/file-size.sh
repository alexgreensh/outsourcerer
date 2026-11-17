#!/usr/bin/env bash
# file-size: the repo's own 1,000-line ratchet (scripts/check_file_size.py), both the checker and its
# .file-size-allow taken from the base ref. Checks every changed path in the working tree, so
# uncommitted and untracked files count. A repo without the checker passes.
set -u
git cat-file -e "$OSRC_GUARD_BASE_REF:scripts/check_file_size.py" 2>/dev/null || exit 0
git show "$OSRC_GUARD_BASE_REF:scripts/check_file_size.py" >"$OSRC_GUARD_TMP/check_file_size.py" || exit 0
python3 -I - "$OSRC_GUARD_TMP/check_file_size.py" <<'PY'
import importlib.util, os, sys
from pathlib import Path
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
spec = importlib.util.spec_from_file_location("osrc_check_file_size", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
need = ("load_allow", "allowed", "is_code", "count_lines", "lines_at", "verdict", "MAX_LINES")
if not all(hasattr(m, n) for n in need):
    print("WHAT: the base scripts/check_file_size.py has an unknown interface")
    print("FIX: run python3 scripts/check_file_size.py by hand before READY")
    sys.exit(1)
root = Path.cwd()
globs = m.load_allow(Path(os.environ["OSRC_GUARD_CFGDIR"]))  # .file-size-allow from the base ref
bad = []
with open(os.environ["OSRC_GUARD_FILES"], encoding="utf-8", errors="replace") as f:
    for rel in dict.fromkeys(l.rstrip("\n") for l in f if l.strip()):
        p = root / rel
        if not m.is_code(rel) or m.allowed(rel, globs) or not p.is_file():
            continue
        new = m.count_lines(p.read_text(encoding="utf-8", errors="replace"))
        msg = m.verdict(rel, new, m.lines_at(root, os.environ["OSRC_GUARD_BASE"], rel), m.MAX_LINES)
        if msg:
            bad.append(msg)
for msg in bad:
    print("WHAT: " + msg)
if bad:
    print("FIX: move the new code into a new module file; a file already over the limit may only shrink")
sys.exit(1 if bad else 0)
PY
