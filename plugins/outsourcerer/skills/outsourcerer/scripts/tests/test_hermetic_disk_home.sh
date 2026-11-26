#!/usr/bin/env bash
# test_hermetic_disk_home.sh — every OSRC_HOME a test launches the engine from (run/bg/fanout/loop/
# session start) must write disk-policy/settings with OSRC_DISK_MIN_GB=0 and OSRC_DISK_PAUSE_GB=0.
# Otherwise the host's real free space decides the test (a Mac with 4GB free fails the launch floor).
# Static scan. A named home ("$H3", "$PACAT/osrc") must have its own <home>/disk-policy write; a
# helper-parameter home ($1, $h, ...) needs the file to write disk settings somewhere. Bg preflight
# dry runs (--osrc-preflight-internal) skip the disk gate and are exempt. Arg: dir to scan (self-test).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
python3 -B - "${1:-$HERE}" <<'PY'
import re, sys, glob, os
launch = re.compile(r'(?:outsourcerer\.sh|"\$\{?\w+\}?(?:/outsourcerer\.sh)?")\s+(?:--?[\w-]+(?:\s+[\w.-]+)?\s+)*?(run|bg|fanout|loop|session\s+start)\s')
bad = 0
for f in sorted(glob.glob(os.path.join(sys.argv[1], 'test_*.sh'))):
    s = open(f, errors='replace').read(); L = s.splitlines()
    if 'outsourcerer.sh' not in s or f.endswith('test_hermetic_disk_home.sh'): continue
    writes_any = 'OSRC_DISK_MIN_GB=0' in s and 'OSRC_DISK_PAUSE_GB=0' in s
    homes = set()
    for i, l in enumerate(L):
        if launch.search(l) and '--osrc-preflight-internal' not in l:
            ctx = '\n'.join(L[max(0, i-3):i+1])
            homes.update(re.findall(r'OSRC_HOME="?([^"\s;)]+)', ctx))
    for h in sorted(homes):
        param = re.fullmatch(r'\$\{?([0-9]|[a-z_][a-z0-9_]*)\}?|\$\(\w+', h)
        ok = writes_any if param else (writes_any and re.search(re.escape(h) + r'"?/disk-policy', s))
        if not ok:
            bad += 1; print(f"FAIL: {os.path.basename(f)}: launches from OSRC_HOME={h} without writing its disk-policy/settings")
print(f"RESULT: {bad} unhermetic test home(s)")
sys.exit(1 if bad else 0)
PY
rc=$?
[ -n "${1:-}" ] && exit $rc
# self-test: a launch from a home with no disk settings is caught
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; export HOME="$T"
printf 'H9="$T/h9"; mkdir -p "$H9"\nOSRC_HOME="$H9" bash "$SRC" run -m x "hi"  # outsourcerer.sh\n' > "$T/test_x.sh"
if bash "$0" "$T" >/dev/null 2>&1; then echo "FAIL: self-test: an unhermetic home was not caught"; exit 1; fi
echo "PASS: self-test catches a launch home without disk settings"
exit $rc
