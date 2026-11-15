#!/usr/bin/env python3
"""Keep shell-suite scratch independent of the read-only checkout."""
from pathlib import Path
import importlib.util
import io
import re
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

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


def untrimmed_tmpdir_joins(source):
    return [number for number, line in enumerate(source.splitlines(), 1)
            if not line.lstrip().startswith('#')
            and re.search(r'\$(?:TMPDIR|\{TMPDIR(?::-[^{}]*)?\}\}*)/', line)]


class ShellScratch(unittest.TestCase):
    def test_matrix_alarm_persists_current_row_and_stops(self):
        import json
        spec = importlib.util.spec_from_file_location('alarm_matrix', ROOT / 'scripts/sealed_host_matrix.py')
        matrix = importlib.util.module_from_spec(spec); spec.loader.exec_module(matrix)
        with tempfile.TemporaryDirectory(prefix='osrc-matrix-alarm-') as d:
            root = Path(d); scripts = root / 'scripts'; tests = scripts / 'tests'; tests.mkdir(parents=True)
            for name in ('first', 'alarm', 'last'):
                (tests / ('test_' + name + '.sh')).write_text('exit 0\n')
            def run(command, directory, env, output, timeout):
                output.write_text('')
                if command[-1].endswith('test_alarm.sh'):
                    signal.raise_signal(signal.SIGALRM)
                return 0
            argv = ['matrix', '--suites', 'test_first', 'test_alarm', 'test_last', '--mode', 'direct']
            handler = signal.getsignal(signal.SIGALRM)
            with mock.patch.dict(matrix.__dict__, ROOT=root, SCRIPTS=scripts, TESTS=tests), \
                    mock.patch.object(sys, 'argv', argv), mock.patch.object(sys, 'stdout', new_callable=io.StringIO), \
                    mock.patch.object(matrix.subprocess, 'check_output', return_value='fixture\n'), \
                    mock.patch.object(matrix, 'run', side_effect=run):
                self.assertEqual(matrix.main(), 142)
            self.assertEqual(signal.getsignal(signal.SIGALRM), handler)
            proof = next((root / '.evidence-L14c').glob('host-*'))
            rows = [json.loads(line) for line in (proof / 'results.jsonl').read_text().splitlines()]
            self.assertEqual([(row['suite'], row['rc']) for row in rows],
                             [('test_first.sh', 0), ('test_alarm.sh', 142)])
            self.assertIn('SIGALRM', rows[-1]['reason'])
            self.assertIn('142', (proof / 'matrix.md').read_text())

    def test_matrix_filters_and_incremental_timeout_results(self):
        spec = importlib.util.spec_from_file_location('host_matrix', ROOT / 'scripts/sealed_host_matrix.py')
        matrix = importlib.util.module_from_spec(spec); spec.loader.exec_module(matrix)
        with tempfile.TemporaryDirectory(prefix='osrc-matrix-parts-') as d:
            root = Path(d); scripts = root / 'scripts'; tests = scripts / 'tests'; tests.mkdir(parents=True)
            (tests / 'test_first.sh').write_text('exit 0\n')
            (tests / 'test_slow.sh').write_text('sleep 10\n')
            run = matrix.run
            def observe(command, directory, env, output, timeout):
                self.assertTrue(env['TMPDIR'].endswith('/'))
                if command[-1].endswith('test_slow.sh'):
                    proof = next((root / '.evidence-L14c').glob('host-*'))
                    rows = (proof / 'results.jsonl').read_text().splitlines()
                    self.assertEqual(len(rows), 1, 'first result was not persisted before the next suite')
                    self.assertIn('test_first.sh', (proof / 'matrix.md').read_text())
                return run(command, directory, env, output, timeout)
            argv = ['matrix', '--suites', 'test_first,test_slow', '--mode', 'direct', '--timeout', '0.1']
            with mock.patch.dict(matrix.__dict__, ROOT=root, SCRIPTS=scripts, TESTS=tests), \
                    mock.patch.object(sys, 'argv', argv), mock.patch.object(sys, 'stdout', new_callable=io.StringIO), \
                    mock.patch.object(matrix.subprocess, 'check_output', return_value='fixture\n'), \
                    mock.patch.object(matrix, 'run', side_effect=observe):
                self.assertEqual(matrix.main(), 1)
            import json
            proof = next((root / '.evidence-L14c').glob('host-*'))
            rows = [json.loads(line) for line in (proof / 'results.jsonl').read_text().splitlines()]
            self.assertEqual([(row['suite'], row['mode'], row['rc']) for row in rows],
                             [('test_first.sh', 'direct', 0), ('test_slow.sh', 'direct', 124)])
            self.assertTrue(all(row['tmpdir'].endswith('/') for row in rows))
            self.assertIn('124', (proof / 'matrix.md').read_text())

    def test_shell_scratch_trims_and_canonicalizes_tmpdir(self):
        for path in HERE.glob('*.sh'):
            source = path.read_text()
            with self.subTest(suite=path.name):
                self.assertEqual(untrimmed_tmpdir_joins(source), [])
                if '${TMPDIR%/}/' in source:
                    self.assertIn('. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh"', source)

    def test_product_scratch_trims_tmpdir(self):
        scripts = HERE.parent
        bad = [str(path.relative_to(scripts)) + ':' + str(line)
               for path in scripts.rglob('*.sh') if HERE not in path.parents
               for line in untrimmed_tmpdir_joins(path.read_text())]
        self.assertEqual(bad, [], 'untrimmed product TMPDIR joins: ' + ', '.join(bad))

    def test_product_allocations_with_a_trailing_slash(self):
        with tempfile.TemporaryDirectory(prefix='osrc-product-slash-') as d:
            root = Path(d); bindir = root / 'bin'; bindir.mkdir()
            state = root / 'state'; state.mkdir(); (state / 'work').mkdir()
            stub = bindir / 'mktemp'
            stub.write_text('#!/bin/sh\nprintf "%s\\n" "$@" >> "$OSRC_HOME/templates"\nexec /usr/bin/mktemp "$@"\n')
            stub.chmod(0o755)
            script = '''set -eu
_timeout() { shift; "$@"; }
die() { echo "$*" >&2; exit 1; }
. "$1/lib/perm.sh"
. "$1/lib/parity.sh"
. "$1/lib/cloudgate.sh"
. "$1/lib/heavy.sh"
_session_probe_help /bin/echo probe >/dev/null
_session_assert_model_pinnable stub /bin/echo --model
_insource_block() { printf bridge; }
printf original > "$OSRC_HOME/insource"
_insource_write "$OSRC_HOME/insource" stub
cd "$OSRC_HOME/work"
_cred_file_hits
_osrc_heavy_lockdir
'''
            result = subprocess.run(['/bin/bash', '-c', script, 'product-scratch', str(HERE.parent)],
                                    env={'PATH': str(bindir) + ':/usr/bin:/bin', 'HOME': d,
                                         'OSRC_HOME': str(state) + '/', 'TMPDIR': str(root) + '/'},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            templates = (state / 'templates').read_text().splitlines()
            self.assertEqual(len(templates), 5)
            for template in templates:
                self.assertNotIn('//', template)
                self.assertEqual(Path(template).parent, root)
            self.assertEqual(result.stdout.strip(), str(state / 'heavy-local.lock.d'))

    def test_named_scratch_with_a_trailing_slash_and_symlink(self):
        with tempfile.TemporaryDirectory(prefix='osrc-slash-') as d:
            root = Path(d); real = root / 'real'; real.mkdir()
            alias = root / 'alias'; alias.symlink_to(real, target_is_directory=True)
            for name in NAMED:
                source = (HERE / f'test_{name}.sh').read_text()
                allocation = next(line for line in source.splitlines() if '="$(mktemp -d ' in line)
                script = '. "$1/lib_scratch.sh"\n' + allocation + '\nprintf "%s\\n" "$TMP"\n'
                with self.subTest(suite=name):
                    result = subprocess.run(['/bin/bash', '-u', '-c', script, str(HERE / 'probe.sh'), str(HERE)],
                                            env={'PATH': '/usr/bin:/bin', 'HOME': d, 'OSRC_HOME': str(root / 'state'),
                                                 'TMPDIR': str(alias) + '/'}, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    allocated = result.stdout.strip()
                    self.assertNotIn('//', allocated)
                    self.assertEqual(Path(allocated).parent, real.resolve())

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
