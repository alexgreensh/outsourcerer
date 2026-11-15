#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_sandbox.sh" || { echo "FAIL: sandbox library" >&2; exit 1; }
osrc_test_sandbox || { echo "FAIL: sandbox" >&2; exit 1; }
set -eu
TESTS="$(cd "$(dirname "$0")" && pwd)"
# An optional path lets the negative control and callers check individual files.
python3 - "$TESTS" "$@" <<'PY'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
paths = [pathlib.Path(p) for p in sys.argv[2:]] or sorted(root.glob('test_*.sh'))
source = re.compile(r'''(?:^|[;\s(])(?:source|\.)\s+["']?([^\s;"']+)''')
assignment = re.compile(r'\b([A-Za-z_][A-Za-z_0-9]*)=(.*)')
value = r'''(?:"[^"]*"|'[^']*'|[^\s;]+)'''
home_assignment = re.compile(
    r'''(?:^|;)\s*\(?\s*(?:export\s+(?:[A-Za-z_]\w*=''' + value + r'''\s+)*OSRC_HOME=(''' + value +
    r''')|OSRC_HOME=(''' + value + r''')(?:\s*(?:;|$)))''')
bad = []
for path in paths:
    safe = False
    sandbox_loaded = False
    aliases = set()
    heredoc = None
    for number, line in enumerate(path.read_text().splitlines(), 1):
        stripped = line.strip()
        if heredoc:
            if stripped == heredoc:
                heredoc = None
            continue
        if not stripped or stripped.startswith('#'):
            continue
        h = re.search(r'<<-?\s*["\']?([A-Za-z_][A-Za-z_0-9]*)["\']?', line)
        if h:
            heredoc = h.group(1)
        if 'lib_sandbox.sh' in line and source.search(line):
            if not re.search(r'\|\|\s*\{.*\bexit\s+1\s*;', line):
                bad.append(f'{path}:{number}: sandbox library load must stop on failure')
            else:
                sandbox_loaded = True
            continue
        if re.match(r'\s*osrc_test_sandbox(?:\s|$)', line):
            if not sandbox_loaded or not re.search(r'\|\|\s*\{.*\bexit\s+1\s*;', line):
                bad.append(f'{path}:{number}: sandbox must stop on failure')
            else:
                safe = True
            continue
        hit = source.search(line)
        prefix = line[:hit.start()] if hit else line
        for home in home_assignment.finditer(prefix):
            value_text = home.group(1) or home.group(2)
            safe = not re.search(r'\$HOME|\$\{HOME(?:\}|[:?+/-])|~', value_text)
        if hit:
            target = hit.group(1)
            var = re.match(r'\$\{?([A-Za-z_][A-Za-z_0-9]*)', target)
            engine = 'outsourcerer.sh' in line[hit.start():] or (var and var.group(1) in aliases)
            if engine and not safe:
                bad.append(f'{path}:{number}: sources outsourcerer.sh before sandbox')
        a = assignment.search(line)
        if a:
            name, value = a.groups()
            if 'outsourcerer.sh' in value or any(re.search(r'\$\{?' + re.escape(v) + r'(?:\}|\b)', value) for v in aliases):
                aliases.add(name)
        # Recognize copies made with sed before a source of the temporary result.
        copy = re.search(r'''\bsed\b.*\$\{?([A-Za-z_][A-Za-z_0-9]*)\}?["']?\s*>\s*["']?\$\{?([A-Za-z_][A-Za-z_0-9]*)''', line)
        if copy and copy.group(1) in aliases:
            aliases.add(copy.group(2))
if bad:
    print('\n'.join(bad), file=sys.stderr)
    sys.exit(1)
print(f'PASS: sandbox precedes engine sourcing in {len(paths)} test files')
PY
if [ "$#" -eq 0 ]; then
  printf '%s\n' 'SRC="../outsourcerer.sh"' '. "$SRC"' 'OSRC_HOME=/too-late' > "$OSRC_TEST_ROOT/bad.sh"
  if bash "$0" "$OSRC_TEST_ROOT/bad.sh" > "$OSRC_TEST_ROOT/bad.out" 2>&1; then
    echo 'FAIL: guard accepted a source before sandboxing' >&2
    exit 1
  fi
  grep -q 'before sandbox' "$OSRC_TEST_ROOT/bad.out"
  printf '%s\n' 'SRC="../outsourcerer.sh"' 'OSRC_HOME=/isolated' '. "$SRC"' > "$OSRC_TEST_ROOT/good.sh"
  bash "$0" "$OSRC_TEST_ROOT/good.sh"
  echo 'PASS: guard rejects an unsandboxed temporary test'
  printf '%s\n' '. "lib_sandbox.sh"' 'osrc_test_sandbox' > "$OSRC_TEST_ROOT/unchecked.sh"
  if bash "$0" "$OSRC_TEST_ROOT/unchecked.sh" > "$OSRC_TEST_ROOT/unchecked.out" 2>&1; then
    echo 'FAIL: guard accepted unchecked sandbox setup' >&2
    exit 1
  fi
  grep -q 'must stop on failure' "$OSRC_TEST_ROOT/unchecked.out"
  echo 'PASS: guard rejects unchecked sandbox setup'
  for setup in 'OSRC_HOME=/tmp/x bash "$SRC" doctor' \
    'echo "set OSRC_HOME=/x first"' 'f() { OSRC_HOME=/x; }' \
    'export OSRC_HOME="$HOME/.outsourcerer"' 'export OSRC_HOME=~/.outsourcerer'; do
    printf '%s\n' 'SRC="../outsourcerer.sh"' "$setup" '. "$SRC"' > "$OSRC_TEST_ROOT/unsafe.sh"
    if bash "$0" "$OSRC_TEST_ROOT/unsafe.sh" > "$OSRC_TEST_ROOT/unsafe.out" 2>&1; then
      echo "FAIL: guard accepted unsafe setup: $setup" >&2
      exit 1
    fi
    grep -q 'before sandbox' "$OSRC_TEST_ROOT/unsafe.out"
  done
  echo 'PASS: guard rejects nonpersistent and real-home settings'
fi
