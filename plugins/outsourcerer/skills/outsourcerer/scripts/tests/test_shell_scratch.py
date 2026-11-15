#!/usr/bin/env python3
"""Keep shell-suite scratch independent of the read-only checkout."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
NAMED = ('approver_table', 'approver_tick', 'cleanup_manifest', 'done_contract',
         'hub', 'remote_review', 'screen_state', 'supervise')
REPO_REF = re.compile(r'\$(?:\{)?(?:HERE|SCRIPT_DIR|PWD|ROOT)(?=[^A-Za-z0-9_]|$)|\$\((?:pwd|dirname)\b')


def repo_scratch(source):
    found = []
    for number, line in enumerate(source.splitlines(), 1):
        if line.lstrip().startswith('#'): continue
        for match in re.finditer(r'(?:\$\(|`|^|[;&|])\s*(?:(?:if|!|command)\s+)*(?:/[A-Za-z0-9_./-]*/)?mktemp\s+([^\n)`]*)', line):
            args = match.group(1)
            if not re.search(r'(?:^|\s)(?:-d|--directory)(?:\s|$)', args): continue
            if REPO_REF.search(args):
                found.append(number); continue
            # A relative template also depends on the caller's working directory.
            words = args.replace('"', '').replace("'", '').split()
            paths = [word for word in words if not word.startswith('-')]
            if any(not word.startswith(('/', '$')) for word in paths): found.append(number)
    return found


class ShellScratch(unittest.TestCase):
    def test_all_shell_suites_avoid_repo_scratch(self):
        bad = [f'{path.name}:{line}' for path in HERE.glob('*.sh') for line in repo_scratch(path.read_text())]
        self.assertEqual(bad, [], 'repo scratch allocations: ' + ', '.join(bad))

    def test_guard_detects_repository_and_relative_templates(self):
        for command in ['mktemp -d "$HERE/.test.XXXXXX"', 'mktemp -d "${SCRIPT_DIR}/x.XXXXXX"',
                        'mktemp -d "$PWD/x.XXXXXX"', 'mktemp -d "${TMPDIR:-$ROOT/tests}/x.XXXXXX"',
                        'mktemp --directory -p "$HERE" x.XXXXXX', 'mktemp -d .test.XXXXXX',
                        'if mktemp -d "$HERE/x.XXXXXX"; then :; fi', 'T="$( /usr/bin/mktemp -d "$PWD/x.XXXXXX")"']:
            with self.subTest(command=command): self.assertTrue(repo_scratch(command))
        for command in ['mktemp -d', 'mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX"', 'mktemp -d "$TMP/child.XXXXXX"', 'echo "FAIL: mktemp -d failed"']:
            with self.subTest(command=command): self.assertFalse(repo_scratch(command))

    def test_named_suites_stop_when_scratch_allocation_fails(self):
        with tempfile.TemporaryDirectory(prefix='osrc-scratch-guard-') as d:
            p = Path(d); stub = p / 'mktemp'; stub.write_text('#!/bin/sh\nexit 71\n'); stub.chmod(0o755)
            for name in NAMED:
                path = HERE / f'test_{name}.sh'
                line = next(line for line in path.read_text().splitlines() if '="$(mktemp -d ' in line)
                # Execute just the allocation line; never run an unsafe legacy body with TMP empty.
                script = 'HERE="$1"; SCRIPT_DIR="$1"; ' + line + '\nprintf continued\n'
                with self.subTest(suite=name):
                    result = subprocess.run(['/bin/bash', '-u', '-c', script, 'scratch-test', str(HERE)],
                                            env={'PATH': d, 'HOME': d, 'OSRC_HOME': str(p / 'state'), 'TMPDIR': d},
                                            capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertNotIn('continued', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
