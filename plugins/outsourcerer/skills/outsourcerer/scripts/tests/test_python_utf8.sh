#!/usr/bin/env bash
# Static gate: shipped Python never decodes text with the locale codec.
# Windows runners default to cp1252, so a bare open()/read_text()/text=True
# subprocess dies on the first non-cp1252 byte (CI run 43768993869 died on 0x8f).
# Scans every .py the plugin ships and the Python embedded in shipped shell
# (`python3 -c '...'` and `python3 - <<'TAG'` heredocs). tests/ is excluded.
# Usage: bash test_python_utf8.sh [plugin-root]   (default: this plugin)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
  printf 'SKIP: python3 is required for the UTF-8 decode gate\n'; exit 0
fi
python3 -I - "${1:-$HERE/../../../..}" <<'PY'
import ast, pathlib, re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
U8 = dict(encoding='utf-8', errors='replace')

OPENERS = {('', 'open'): 1, ('io', 'open'): 1, ('os', 'fdopen'): 1, ('codecs', 'open'): 1}
SUBPROC = {'run', 'Popen', 'check_output', 'call', 'check_call', 'getoutput', 'getstatusoutput'}
STDIN_OK = {'buffer', 'reconfigure', 'isatty', 'fileno', 'close'}

def kw(call, name):
    return next((k.value for k in call.keywords if k.arg == name), None)

def truthy(node):
    return node is not None and not (isinstance(node, ast.Constant) and not node.value)

def func_name(call):
    f = call.func
    if isinstance(f, ast.Name): return '', f.id
    if isinstance(f, ast.Attribute):
        base = f.value.id if isinstance(f.value, ast.Name) else '?'
        return base, f.attr
    return None, None

def binary_mode(call, pos):
    mode = kw(call, 'mode')
    if mode is None and len(call.args) > pos: mode = call.args[pos]
    if mode is None: return False
    return isinstance(mode, ast.Constant) and isinstance(mode.value, str) and 'b' in mode.value

def problems(src):
    tree = ast.parse(src)
    out = []
    stdin_fixed = re.search(r'sys\.stdin\.reconfigure\([^)]*encoding', src) is not None
    for n in ast.walk(tree):
        if isinstance(n, ast.Call):
            base, name = func_name(n)
            enc = kw(n, 'encoding') is not None
            if (base, name) in OPENERS:
                if not enc and not binary_mode(n, OPENERS[(base, name)]):
                    out.append((n.lineno, f'{name}() in text mode without encoding='))
            elif name in ('read_text', 'write_text') and not enc:
                out.append((n.lineno, f'.{name}() without encoding='))
            elif name == 'open' and base not in ('', 'io', 'os', 'codecs', 'webbrowser', 'tarfile', 'zipfile') \
                    and not enc and not binary_mode(n, 0):
                out.append((n.lineno, 'Path.open() in text mode without encoding='))
            elif base == 'subprocess' and name in SUBPROC and not enc:
                if name in ('getoutput', 'getstatusoutput') or truthy(kw(n, 'text')) or truthy(kw(n, 'universal_newlines')):
                    out.append((n.lineno, f'subprocess.{name}() decodes text without encoding='))
        if isinstance(n, ast.Attribute) and n.attr == 'stdin' and isinstance(n.value, ast.Name) and n.value.id == 'sys':
            out.append((n.lineno, 'sys.stdin'))
    # sys.stdin is fine through .buffer / after reconfigure(encoding=...).
    ok_lines = {a.lineno for a in ast.walk(tree) if isinstance(a, ast.Attribute) and a.attr in STDIN_OK
                and isinstance(a.value, ast.Attribute) and a.value.attr == 'stdin'}
    return sorted((l, m if m != 'sys.stdin' else 'sys.stdin read in the locale codec (use .buffer or reconfigure(encoding=))')
                  for l, m in out if not (m == 'sys.stdin' and (stdin_fixed or l in ok_lines)))

PY_CALL = re.compile(r'(?:^|[\s;&|(`"$])(?:\S*/)?python3?(?:\.\d+)?\b')
HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1")

def shell_snippets(text):
    """Yield (start_line, code) for Python embedded in a shell script."""
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        line = lines[i]
        m = PY_CALL.search(line)
        if m and not line.lstrip().startswith('#'):
            rest = line[m.end():]
            h = HEREDOC.search(rest)
            c = re.search(r"\s-c\s+'", rest)
            if h and re.search(r'(^|\s)-(\s|$)', rest[:h.start()] + ' '):
                tag, body, j = h.group(2), [], i + 1
                while j < len(lines) and lines[j].strip() != tag:
                    body.append(lines[j]); j += 1
                yield i + 2, '\n'.join(body)
                i = j + 1; continue
            if c:
                buf = rest[c.end():]
                j = i
                while "'" not in buf and j + 1 < len(lines):
                    j += 1; buf += '\n' + lines[j]
                yield i + 1, buf.split("'", 1)[0]
                i = j + 1; continue
        i += 1

def scan(root):
    found, units = [], 0
    for path in sorted(root.rglob('*')):
        if not path.is_file() or 'tests' in path.relative_to(root).parts or 'node_modules' in path.parts:
            continue
        if path.suffix == '.py':
            units += 1
            try: found += [(path, l, m) for l, m in problems(path.read_text(**U8))]
            except SyntaxError as e: found.append((path, e.lineno or 0, f'unparseable: {e.msg}'))
        elif path.suffix in ('.sh', '.bash') or path.name == 'outsourcerer':
            for start, code in shell_snippets(path.read_text(**U8)):
                units += 1
                try: found += [(path, start + l - 1, m) for l, m in problems(code)]
                except SyntaxError as e: found.append((path, start, f'embedded Python unparseable: {e.msg}'))
    return found, units

# Self-check: the gate must flag every bad form and none of the good ones.
bad = ["open(p)", "open(p, 'r')", "open(p, 'w')", "open(p, mode='a')", "io.open(p)", "os.fdopen(fd, 'w')",
       "pathlib.Path(p).read_text()", "q.write_text(s)", "q.open()", "subprocess.run(a, text=True)",
       "subprocess.check_output(a, universal_newlines=True)", "subprocess.getoutput(c)", "sys.stdin.read()",
       "json.load(sys.stdin)", "for l in sys.stdin: pass"]
good = ["open(p, 'rb')", "open(p, mode='wb')", "open(p, encoding='utf-8')", "os.fdopen(fd, 'wb')",
        "q.read_text(encoding='utf-8', errors='replace')", "q.open('rb')", "subprocess.run(a, capture_output=True)",
        "subprocess.run(a, text=True, encoding='utf-8')", "sys.stdin.buffer.read()", "webbrowser" ".open(u)",
        "sys.stdin.reconfigure(encoding='utf-8')\nsys.stdin.read()", "b.decode('utf-8', 'replace')"]
failed = 0
for code in bad:
    if not problems(code): print(f'FAIL: gate missed: {code}'); failed += 1
for code in good:
    if problems(code): print(f'FAIL: gate false positive: {code} -> {problems(code)}'); failed += 1
sh = "x=$(python3 -I -c 'import sys\nprint(open(sys.argv[1]).read())' f)\npython3 - a <<'PY'\nimport pathlib\npathlib.Path('x').write_text('y')\nPY\n"
got = [l for l, _ in ((s + l - 1, m) for s, c in shell_snippets(sh) for l, m in problems(c))]
if got != [2, 5]: print(f'FAIL: embedded shell Python lines {got} != [2, 5]'); failed += 1

root = pathlib.Path(sys.argv[1]).resolve()
found, units = scan(root)
for path, line, msg in found:
    print(f'FAIL: {path.relative_to(root)}:{line}: {msg}'); failed += 1
if units < 5:
    print(f'FAIL: only {units} Python units found under {root}; scan root is wrong'); failed += 1
if failed: sys.exit(1)
print(f'PASS: {units} shipped Python units decode text as UTF-8 explicitly ({len(bad)}+{len(good)} self-checks)')
PY
