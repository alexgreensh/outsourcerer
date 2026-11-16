#!/usr/bin/env bash
# Tests and scripts must never pop a real browser or touch the macOS keychain.
#
# Why (2026-11-15, KC): every suite runs with HOME=<tmp>/home (test_tests_set_home enforces it).
# A Chrome started under that HOME looks for its "Chrome Safe Storage" key, finds no
# ~/Library/Keychains, gets errSecNoDefaultKeychain (-25307), and macOS throws a modal
# "Keychain Not Found ... to store 'Chrome'" dialog at the person, once per launch. The MC3
# screenshot rehearsal did this 15 times in 20 minutes. Fixtures: fixtures/no_real_browser/.
#
# Rules, per logical line (backslash continuations joined), comments ignored:
#   1. A line that starts Chrome/Chromium/Edge/Brave or runs `--headless` must pass
#      --use-mock-keychain (Chrome then never asks the keychain).
#   2. Test code may not open a browser at all: no webbrowser.open, `open http...`,
#      `open -a <browser>`, xdg-open, or AppleScript `open location`.
#   3. `hub serve` in a test must pass --no-open (or the file sets OSRC_HUB_NO_OPEN=1).
# Usage: test_no_real_browser.sh [dir]  (default: the scripts/ dir, fixtures excluded)
set -uo pipefail
if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is required for the no-real-browser guard"
  exit 1
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"   # static scan only; set anyway so test_tests_set_home holds

scan() {
python3 -B - "$1" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
EXT = {'.sh', '.bash', '.py', '.js', '.mjs', '.cjs', '.ts'}
LAUNCH = re.compile(r'(Google Chrome(?! Helper)|Chromium\.app|chrome-headless-shell|Microsoft Edge\.app'
                    r'|Brave Browser\.app|(^|[\s"\'/])(google-chrome|chromium|chromium-browser)(\s|$|["\'])'
                    r'|--headless\b)')
OPEN = re.compile(r'(webbrowser\.open|(^|[\s;&|(])(/usr/bin/)?open\s+(-a\s+\S+.*)?["\']?https?://'
                  r'|(^|[\s;&|(])(/usr/bin/)?open\s+-a\s+["\']?(Google Chrome|Safari|Firefox|Chromium|Arc)'
                  r'|xdg-open|open location)')
SERVE = re.compile(r'\bhub\s+serve\b')

def logical(text):
    out, buf, start = [], '', 1
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        s = line.lstrip()
        if s.startswith('#') or s.startswith('//'):
            line = ''
        if not buf:
            start = n
        if line.endswith('\\'):
            buf += line[:-1] + ' '
            continue
        out.append((start, buf + line)); buf = ''
    if buf:
        out.append((start, buf))
    return out

bad = []
files = [p for p in sorted(root.rglob('*')) if p.is_file() and p.suffix in EXT
         and 'fixtures' not in p.relative_to(root).parts and p.name != 'test_no_real_browser.sh']
for p in files:
    try:
        text = p.read_text(errors='replace')
    except OSError:
        continue
    rel = str(p.relative_to(root))
    is_test = 'tests' in p.relative_to(root).parts or p.parent == root
    no_open_env = 'OSRC_HUB_NO_OPEN=1' in text
    for n, line in logical(text):
        if not line.strip():
            continue
        if LAUNCH.search(line) and '--use-mock-keychain' not in line \
                and not re.match(r'\s*(ls|which|command -v|test|\[|echo|printf)\b', line) \
                and not re.match(r'''\s*(export\s+|local\s+)?[A-Za-z_]\w*=("[^"]*"|'[^']*'|\S*)\s*;?\s*$''', line):
            bad.append('%s:%d: starts a browser without --use-mock-keychain' % (rel, n))
        if is_test and OPEN.search(line):
            bad.append('%s:%d: opens a real browser from test code' % (rel, n))
        if is_test and SERVE.search(line) and '--no-open' not in line and not no_open_env \
                and re.search(r'(outsourcerer\.sh|\$SRC|\$OSRC|\brun)\b.*hub\s+serve', line):
            bad.append('%s:%d: hub serve without --no-open' % (rel, n))
for b in bad:
    print('BAD ' + b)
print('scanned %d files, %d violation(s)' % (len(files), len(bad)))
sys.exit(1 if bad else 0)
PY
}

fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

if [ $# -gt 0 ]; then scan "$1"; exit $?; fi

# 1. The shipped tree is clean.
out="$(scan "$HERE/..")"; rc=$?
printf '%s\n' "$out" | sed 's/^/     /'
[ $rc -eq 0 ] && ok "scripts/ starts no real browser" || bad "scripts/ starts a real browser (see BAD lines)"

# 2. The real offender is caught: MC3's screenshot rehearsal, copied verbatim.
FX="$HERE/fixtures/no_real_browser"
out="$(scan "$FX/bad")"; rc=$?
n="$(printf '%s\n' "$out" | grep -c '^BAD .*use-mock-keychain')"
[ $rc -ne 0 ] && [ "$n" = 2 ] \
  && ok "real MC3 shot.sh: both Chrome launches flagged" || { printf '%s\n' "$out"; bad "real MC3 shot.sh not flagged"; }
printf '%s\n' "$out" | grep -E '^BAD ' | grep -v use-mock-keychain | grep -E 'open|hub serve' >/dev/null \
  && ok "test-code browser opens flagged" || { printf '%s\n' "$out"; bad "browser opens not flagged"; }

# 3. The fixed copy passes (only the flag differs), so the rule is not just "never mention Chrome".
out="$(scan "$FX/good")"; rc=$?
[ $rc -eq 0 ] && ok "fixed shot.sh (with --use-mock-keychain) passes" || { printf '%s\n' "$out"; bad "fixed shot.sh flagged"; }

[ $fail -eq 0 ] && echo "PASS test_no_real_browser" || echo "FAIL test_no_real_browser"
exit $fail
