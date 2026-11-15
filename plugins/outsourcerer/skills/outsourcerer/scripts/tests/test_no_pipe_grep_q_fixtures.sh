#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# Exercise the guard with isolated shell-text fixtures; fixture commands are never executed.
set -uo pipefail
command -v python3 >/dev/null 2>&1 || { echo 'SKIP: python3 is required for quiet-grep guard fixtures'; exit 0; }
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "${TMPDIR%/}/osrc-grep-fixtures.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
python3 - "$HERE/test_no_pipe_grep_q.sh" "$T" <<'PY'
import os
import pathlib
import subprocess
import sys

guard = sys.argv[1]
root = pathlib.Path(sys.argv[2])
bad = {
    'locale-prefix': 'echo "$x" | LC_ALL=C grep -q P',
    'env-prefix': 'echo "$x" | env LC_ALL=C grep -q P',
    'env-unset': 'echo "$x" | env -u LANG LC_ALL=C grep -q P',
    'egrep': 'echo "$x" | egrep -q P',
    'fgrep': 'echo "$x" | fgrep -q P',
    'command-grep': 'echo "$x" | command grep -q P',
    'absolute-grep': 'echo "$x" | /usr/bin/grep -q P',
    'pipe-stderr': 'echo "$x" |& grep -q P',
    'grep-filter': 'echo "$x" | grep -v a | grep -q P',
    'tr-filter': 'echo "$x" | tr a b | grep -q P',
    'cat-herestring': 'cat <<<"$x" | grep -q P',
    'function-producer': 'some_function arg | grep -q P',
    'command-producer': 'git status | grep -q P',
    'shopt-pipefail': 'echo "$x" | grep -q P',
    'flags-after-pattern': 'echo "$x" | grep -e P -q',
    'escaped-command': 'check "name" "printf \'%s\' \\\"\\$out\\\" | grep -q \'bad\'"',
    'command-substitution': 'v="$(some_function | grep -q P)"',
    'multiline': 'printf x |\n  grep -q P',
    'heredoc-pipeline': 'cat <<END |\n  grep -q P\nP\nEND',
}
good = {
    'trailing-comment': 'echo safe # echo "$x" | grep -q P',
    'quoted-message': 'echo \'echo "$x" | grep -q P\'',
    'double-quoted-message': 'echo "echo \\\"$x\\\" | grep -q P"',
    'quoted-check-description': 'check \'echo "$x" | grep -q P\' true',
    'heredoc': 'cat <<\'END\'\necho "$x" | grep -q P\nEND',
    'escaped-heredoc': 'cat <<\\END\necho "$x" | grep -q P\nEND',
    'literal-substitution': "echo '$(producer | grep -q P)'",
    'here-string': 'grep -q P <<<"$x"',
    'grep-double-dash': 'echo "$x" | grep -- -q',
}
failed = 0
for expected, fixtures in ((True, bad), (False, good)):
    for name, code in fixtures.items():
        setup = 'shopt -so pipefail\n' if name == 'shopt-pipefail' else 'set -uo pipefail\n'
        path = root / (name + '.sh')
        path.write_text(setup + code + '\n')
        result = subprocess.run(['/bin/bash', guard, str(root)], text=True, capture_output=True)
        hit = result.returncode == 1 and f'{path}:2:' in result.stdout
        ok = hit if expected else result.returncode == 0
        print(('PASS: ' if ok else 'FAIL: ') + name + ('' if ok else ': ' + result.stdout + result.stderr))
        failed += not ok
        path.unlink()
status_case = '''set -o pipefail
producer() { printf 'MATCH\\n'; return 7; }
{ captured="$(producer)" && grep -q MATCH <<<"$captured"; }
'''
r = subprocess.run(['/bin/bash', '-c', status_case], text=True, capture_output=True)
ok = r.returncode != 0
print(('PASS: ' if ok else 'FAIL: ') + 'matching output does not hide producer failure')
failed += not ok
env = os.environ.copy()
env['PATH'] = '/nonexistent'
r = subprocess.run(['/bin/bash', guard, str(root)], text=True, capture_output=True, env=env)
ok = r.returncode == 0 and 'SKIP:' in r.stdout and 'python3' in r.stdout
print(('PASS: ' if ok else 'FAIL: ') + 'python3 unavailable skips clearly')
failed += not ok
print(f'RESULT: {len(bad) + len(good) + 2 - failed} passed, {failed} failed')
sys.exit(bool(failed))
PY
