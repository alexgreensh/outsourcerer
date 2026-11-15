#!/usr/bin/env python3
"""Keep shell-suite scratch independent of the read-only checkout."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
NAMED = ('approver_table', 'approver_tick', 'cleanup_manifest', 'done_contract',
         'hub', 'remote_review', 'screen_state', 'supervise')
REPO_REF = re.compile(r'\$(?:\{)?(?:HERE|SCRIPT_DIR|PWD|ROOT|REPO|REPO_ROOT|WORKTREE)(?=[^A-Za-z0-9_]|$)|\$\((?:pwd|dirname|git\s+rev-parse)\b', re.I)


def checkout_path(path):
    if path.startswith('$'):
        return False
    if not path.startswith('/'):
        return True
    return Path(path).resolve().is_relative_to(ROOT)


def repo_scratch(source):
    found = []
    for number, line in enumerate(source.splitlines(), 1):
        if line.lstrip().startswith('#'): continue
        for match in re.finditer(r'(?:\$\(|`|^|[;&|])\s*(?:(?:if|!|command)\s+)*(?:/[A-Za-z0-9_./-]*/)?mktemp\s+([^\n)`]*)', line):
            args = match.group(1)
            if REPO_REF.search(args):
                found.append(number); continue
            # Check defaults even when TMPDIR happens to be set on this host.
            defaults = re.findall(r'\$\{[A-Za-z_][A-Za-z0-9_]*:?[=-]([^{}]*)\}', args)
            if any(checkout_path(default) for default in defaults):
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

    def test_guard_rejects_checkout_fallbacks(self):
        old_line = 'T="$(mktemp -d "${TMPDIR:-.}/osrc-lock-owner.XXXXXX")"'
        self.assertEqual(repo_scratch(old_line), [1])
        for fallback in ('.', './tests', 'tests', '../checkout', '${ROOT}/tests',
                         '$REPO', '${repo_root}', '$WORKTREE', '$(git rev-parse --show-toplevel)',
                         str(HERE), str(ROOT)):
            for operator in ('-', ':-', '=', ':='):
                command = 'mktemp -d "${TMPDIR' + operator + fallback + '}/x.XXXXXX"'
                with self.subTest(command=command):
                    self.assertEqual(repo_scratch(command), [1])
        for command in ('mktemp "${TMPDIR:-.}/file.XXXXXX"',
                        'mktemp -d -p "${TMPDIR:-.}" child.XXXXXX',
                        'mktemp -d "${TMPDIR:-${CACHE:-.}}/child.XXXXXX"'):
            with self.subTest(command=command):
                self.assertEqual(repo_scratch(command), [1])
        self.assertEqual(repo_scratch(old_line.replace('TMPDIR:-.', 'TMPDIR:-/tmp')), [])

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
