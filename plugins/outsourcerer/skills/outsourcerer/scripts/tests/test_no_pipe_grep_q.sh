#!/usr/bin/env bash
# Quiet grep can close the pipe early and make its producer fail under pipefail.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 - "${1:-$HERE}" <<'PY'
import pathlib
import re
import shlex
import sys

root = pathlib.Path(sys.argv[1])
producer = re.compile(r'\b(?:echo|printf)\s+')
grep = re.compile(r'\s*grep\s+')

def pipe_after(text, start):
    single = double = False
    i = start
    while i < len(text):
        char = text[i]
        if char == '\\' and not single:
            i += 2
            continue
        if char == "'" and not double:
            single = not single
        elif char == '"' and not single:
            double = not double
        elif not single and not double:
            if char == '|' and text[i:i+2] != '||':
                return i
            if char == ';' or text[i:i+2] in ('&&', '||'):
                return None
        i += 1
    return None

def quiet_option(text):
    lexer = shlex.shlex(text, posix=True, punctuation_chars='|&;()<>')
    lexer.whitespace_split = True
    skip_argument = False
    try:
        for arg in lexer:
            if arg and all(c in '|&;()<>' for c in arg):
                break
            if skip_argument:
                skip_argument = False
                continue
            if arg == '--':
                break
            if arg in ('-e', '-f', '--regexp', '--file'):
                skip_argument = True
            elif arg in ('--quiet', '--silent') or (
                    arg.startswith('-') and not arg.startswith('--') and 'q' in arg[1:]):
                return True
    except ValueError:
        pass  # A containing quoted shell command may end after this line.
    return False

failed = False
for path in sorted(root.rglob('*.sh')):
    text = path.read_text()
    if not re.search(r'(?m)(?:^|;)\s*set\s+[^\n#]*\bpipefail\b', text):
        continue
    lines = text.splitlines()
    for number, line in enumerate(lines, 1):
        if line.lstrip().startswith('#'):
            continue
        # A pipe or a backslash can continue the command on the next physical line.
        end = number
        while end < len(lines) and line.rstrip().endswith(('|', '\\')):
            line = line.rstrip()
            if line.endswith('\\'):
                line = line[:-1]
            line += ' ' + lines[end].lstrip()
            end += 1
        for match in producer.finditer(line):
            pipe = pipe_after(line, match.end())
            if pipe is None:
                continue
            command = grep.match(line, pipe + 1)
            if not command:
                continue
            if quiet_option(line[command.end():]):
                print(f'{path}:{number}: producer piped into quiet grep')
                failed = True
if failed:
    sys.exit(1)
print('PASS: no echo/printf pipe into quiet grep in pipefail tests')
PY
