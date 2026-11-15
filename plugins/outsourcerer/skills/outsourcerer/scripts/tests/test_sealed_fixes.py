#!/usr/bin/env python3
"""Regression checks that do not require launching an OS sandbox."""
import importlib.util
import ast
import json
import os
from pathlib import Path
import shlex
import re
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parents[4]
REL = SCRIPTS.relative_to(ROOT)
spec = importlib.util.spec_from_file_location('matrix', ROOT / 'scripts/sealed_host_matrix.py')
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)
runner_spec = importlib.util.spec_from_file_location('runner_tests', SCRIPTS / 'tests/test_sealed_runner.py')
runner_tests = importlib.util.module_from_spec(runner_spec)
runner_spec.loader.exec_module(runner_tests)


class SealedFixes(unittest.TestCase):
    def setUp(self):
        self.temp = matrix.suite_scratch()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / 'repo'
        self.root.mkdir()
        self.git('init', '-q', str(self.root))
        self.tests = self.root / REL / 'tests'
        self.tests.mkdir(parents=True)
        self.runner = self.base / 'runner.sh'
        self.source = (SCRIPTS / 'sealed-run.sh').read_text()
        self.env = dict(os.environ, OSRC_HOME=str(self.base / 'state'),
                        HOME=str(self.base), TMPDIR=str(self.base))

    def git(self, *args):
        return subprocess.check_output(['git', *args], text=True).strip()

    def run_runner(self, *args, source=None):
        # Simulate only the backend, retaining the actual runner and test execution.
        source = (source or self.source).replace('case "$(uname -s)" in', 'case NoOS in')
        self.runner.write_text(source)
        return subprocess.run(['/bin/bash', '-p', str(self.runner), '--allow-unisolated', *args],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def suite(self, name, content):
        path = self.tests / (name + '.sh')
        path.write_text(content)
        return str(path.relative_to(self.root))

    def test_reserved_statuses_and_first_failure(self):
        for code in (77, 78):
            with self.subTest(code=code):
                result = self.run_runner(self.suite('reserved', 'exit %d\n' % code))
                self.assertEqual(result.returncode, 1, result.stderr)
        result = self.run_runner(self.suite('first', 'exit 23\n'), self.suite('second', 'exit 42\n'))
        self.assertEqual(result.returncode, 23, result.stderr)

    def test_git_environment_cannot_redirect_root_or_common(self):
        other = self.base / 'private'
        self.git('init', '-q', str(other))
        self.env.update(GIT_DIR=str(other / '.git'), GIT_COMMON_DIR=str(other / '.git'),
                        GIT_WORK_TREE=str(other), GIT_CONFIG_COUNT='1',
                        GIT_CONFIG_KEY_0='core.bare', GIT_CONFIG_VALUE_0='true')
        result = self.run_runner(self.suite('good', 'echo ran-correct-suite\n'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ran-correct-suite', result.stdout)

    def test_forged_common_directory_is_refused_before_execution(self):
        private = self.base / 'private'
        self.git('init', '-q', str(private))
        # A separate gitdir and commondir, both controlled by the checkout.
        fake = self.root / 'fake'
        fake.mkdir()
        (fake / 'commondir').write_text(str(private / '.git') + '\n')
        (fake / 'HEAD').write_text('ref: refs/heads/main\n')
        (self.root / '.git').rename(self.root / 'original-git')
        (self.root / '.git').write_text('gitdir: ' + str(fake) + '\n')
        result = self.run_runner(self.suite('evil', 'echo MUST-NOT-RUN\n'))
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertIn('sealed-run: untrusted git common directory', result.stderr)
        self.assertNotIn('MUST-NOT-RUN', result.stdout)

    def test_backlink_requires_the_reciprocal_gitdir_pointer(self):
        private = self.base / 'private'
        self.git('init', '-q', str(private))
        registered = private / '.git/worktrees/registered'
        registered.mkdir(parents=True)
        (registered / 'gitdir').write_text(str(self.root / '.git') + '\n')
        fake = self.root / 'fake'
        fake.mkdir()
        (fake / 'HEAD').write_text('ref: refs/heads/main\n')
        (fake / 'commondir').write_text(str(private / '.git') + '\n')
        (self.root / '.git').rename(self.root / 'original-git')
        (self.root / '.git').write_text('gitdir: ' + str(fake) + '\n')
        self.assertEqual(self.git('-C', str(self.root), 'rev-parse', '--show-toplevel'), str(self.root))
        suite = self.suite('evil', 'echo MUST-NOT-RUN\n')
        result = self.run_runner(suite)
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertIn('sealed-run: untrusted git common directory', result.stderr)
        self.assertNotIn('MUST-NOT-RUN', result.stdout)
        reciprocal = ' and\n                (root / gitdir[8:]).resolve() == backlink.parent.resolve()'
        self.assertIn(reciprocal, self.source)
        mutant = self.run_runner(suite, source=self.source.replace(reciprocal, '', 1))
        self.assertEqual(mutant.returncode, 0, mutant.stderr)
        self.assertIn('MUST-NOT-RUN', mutant.stdout)

    def test_git_config_cannot_move_the_trusted_checkout_root(self):
        private = self.base / 'private'
        self.git('init', '-q', str(private))
        self.git('-C', str(private), 'config', 'core.worktree', str(private))
        private_tests = private / REL / 'tests'
        private_tests.mkdir(parents=True)
        (private_tests / 'evil.sh').write_text('echo PRIVATE-REPO-READ\n')
        (self.root / '.git').rename(self.root / 'original-git')
        (self.root / '.git').write_text('gitdir: ' + str(private / '.git') + '\n')
        result = self.run_runner(str((REL / 'tests/evil.sh')))
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertIn('sealed-run: git checkout root mismatch', result.stderr)
        self.assertNotIn('PRIVATE-REPO-READ', result.stdout)

    def test_real_linked_worktree_is_accepted(self):
        self.git('-C', str(self.root), '-c', 'user.name=fixture', '-c',
                 'user.email=fixture@example.invalid', '-c', 'core.hooksPath=/dev/null',
                 'commit', '-qm', 'fixture', '--allow-empty')
        linked = self.base / 'linked'
        self.git('-C', str(self.root), 'worktree', 'add', '-q', '--detach', str(linked))
        self.root = linked
        self.tests = linked / REL / 'tests'
        self.tests.mkdir(parents=True)
        result = self.run_runner(self.suite('good', 'echo linked-ran\n'))
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(os.uname().sysname == 'Darwin', 'macOS process refusal')
    def test_mac_process_refusal_also_covers_manual_runs(self):
        suite = self.suite('process', '# sealed-run-requires: process-inspection\necho MUST-NOT-RUN\n')
        for flags in ([], ['--allow-unisolated']):
            result = subprocess.run(['/bin/bash', '-p', str(SCRIPTS / 'sealed-run.sh'), *flags, suite],
                                    cwd=self.root, env=self.env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 77, result.stderr)
            self.assertIn('macOS ps cannot run safely', result.stderr)
            self.assertNotIn('MUST-NOT-RUN', result.stdout)

    def test_scratch_never_lives_in_checkout_even_with_checkout_tmpdir(self):
        self.env['TMPDIR'] = str(self.root)
        result = self.run_runner(self.suite('scratch', 'printf "scratch=%s\\n" "$TMPDIR"\n'))
        self.assertEqual(result.returncode, 0, result.stderr)
        scratch = Path(result.stdout.strip().split('scratch=')[1])
        self.assertNotIn(self.root, scratch.parents)
        self.assertFalse(scratch.parent.exists(), 'runner left scratch after exit')

    def test_linux_mount_order(self):
        # Capture the real argv at the backend boundary, without executing bwrap.
        backend = self.base / 'bwrap'
        backend.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        backend.chmod(0o755)
        source = self.source.replace('case "$(uname -s)" in', 'case Linux in')
        source = source.replace('Linux) [ -x /usr/bin/bwrap ] && isolation=linux ;;',
                                'Linux) isolation=linux ;;')
        source = source.replace('/usr/bin/bwrap --die-with-parent', shlex.quote(str(backend)) + ' --die-with-parent')
        self.runner.write_text(source)
        result = subprocess.run(['/bin/bash', '-p', str(self.runner), '--check-sandbox'],
                                cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = result.stdout.splitlines()
        self.assertLess(args.index('--tmpfs'), args.index(str(self.root / '.git')))

    def test_mac_profile_keeps_host_proven_sysctl_rule(self):
        backend = self.base / 'sandbox-exec'
        backend.write_text('#!/bin/sh\ncat "$2"\n')
        backend.chmod(0o755)
        source = self.source.replace('case "$(uname -s)" in', 'case Darwin in')
        source = source.replace('Darwin) [ -x /usr/bin/sandbox-exec ] && isolation=mac ;;',
                                'Darwin) isolation=mac ;;')
        source = source.replace('$(/usr/bin/env -u DEVELOPER_DIR /usr/bin/xcode-select -p 2>/dev/null)',
                                '$(printf /Library/Developer/CommandLineTools)')
        source = source.replace('/usr/bin/sandbox-exec -f', shlex.quote(str(backend)) + ' -f')
        self.runner.write_text(source)
        result = subprocess.run(['/bin/bash', '-p', str(self.runner), '--check-sandbox'],
                                cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('(allow sysctl-read)', result.stdout)
        self.assertNotIn('sysctl-name', result.stdout)

    def test_mac_profile_reads_external_scratch_without_reading_shared_tmp(self):
        generator = self.source.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        profile = self.base / 'profile.sb'
        scratch = '/private/tmp/sealed-owned-fixture'
        result = subprocess.run(['/usr/bin/python3', '-I', '-', str(profile), str(self.root),
                                 scratch, '', '/Library/Developer/CommandLineTools', str(self.root / '.git')],
                                input=generator, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        policy = profile.read_text()
        self.assertIn('(allow file-read* file-map-executable (subpath "' + scratch + '"))', policy)
        self.assertNotIn('(allow file-read* (subpath "/private/tmp"))', policy)
        self.assertNotIn('(allow file-read* file-map-executable (subpath "/private/tmp"))', policy)

    def test_mac_profile_allows_temp_ancestor_metadata_without_temp_contents(self):
        generator = self.source.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        profile = self.base / 'ancestors.sb'
        root = '/private/tmp/checkout/work'
        scratch = '/private/tmp/scratch/run'
        common = '/private/var/tmp/main/.git'
        result = subprocess.run(['/usr/bin/python3', '-I', '-', str(profile), root, scratch,
                                 '', '/Library/Developer/CommandLineTools', common],
                                input=generator, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        policy = profile.read_text()
        for parent in ('/', '/private', '/private/tmp', '/private/tmp/checkout',
                       '/private/tmp/scratch', '/private/var', '/private/var/tmp', '/private/var/tmp/main'):
            self.assertIn('(allow file-read-metadata (literal "' + parent + '"))', policy)
            self.assertNotIn('(deny file-read-metadata (literal "' + parent + '"))', policy)
        for parent in ('/tmp', '/private/tmp', '/var/tmp', '/private/var/tmp'):
            denial = '(deny file-read-metadata (literal "' + parent + '"))'
            if os.path.realpath(parent) in ('/private/tmp', '/private/var/tmp'):
                self.assertNotIn(denial, policy)
            else:
                self.assertIn(denial, policy)
            self.assertNotIn('(allow file-read* (subpath "' + parent + '"))', policy)
            self.assertNotIn('(allow file-read* file-map-executable (subpath "' + parent + '"))', policy)
        self.assertIn('(deny file-read-metadata (literal "/usr/tmp"))', policy)

    def test_matrix_timeout_terminates_then_kills_and_cleans_scratch(self):
        script = self.base / 'wait.sh'
        script.write_text('trap "echo terminated; exit 0" TERM\nmkdir "$TMPDIR/.osrc-sealed.owned"\nwhile :; do sleep 1; done\n')
        output = self.base / 'output.log'
        with matrix.suite_scratch() as owned:
            temp = Path(owned)
            env = dict(self.env, TMPDIR=owned)
            rc = matrix.run(['/bin/bash', str(script)], self.base, env, output, .3)
            self.assertEqual(rc, 124)
            self.assertIn('terminated', output.read_text())
            self.assertTrue((temp / '.osrc-sealed.owned').exists(), 'run removed caller-owned scratch')
        self.assertFalse(temp.exists(), 'owning context did not clean up after the timeout')

    def test_matrix_run_preserves_foreign_scratch_in_shared_tmpdir(self):
        foreign = self.base / '.osrc-sealed.foreign'
        foreign.mkdir()
        (foreign / 'canary').write_text('belongs to another run')
        rc = matrix.run(['/bin/sh', '-c', 'exit 0'], self.base, self.env, self.base / 'output.log', 2)
        self.assertEqual(rc, 0)
        self.assertTrue(foreign.exists(), 'run deleted scratch it did not create')
        self.assertEqual((foreign / 'canary').read_text(), 'belongs to another run')

    def test_matrix_row_cleans_only_its_created_scratch_after_timeout(self):
        foreign = self.base / '.osrc-sealed.foreign'
        foreign.mkdir()
        created = []
        def timeout(command, directory, env, output, seconds):
            owned = Path(env['TMPDIR'])
            self.assertTrue(owned.exists())
            (owned / '.osrc-sealed.owned').mkdir()
            created.append(owned)
            output.write_text('MATRIX_TIMEOUT: fixture\n')
            return 124
        args = ['matrix', '--suite', 'test_done_contract', '--mode', 'sealed', '--out', str(self.base / 'proof')]
        with mock.patch.object(matrix, 'run', side_effect=timeout), mock.patch('sys.argv', args), mock.patch('sys.stdout'):
            self.assertEqual(matrix.main(), 1)
        self.assertEqual(len(created), 1)
        self.assertFalse(created[0].exists(), 'matrix row left its owned scratch behind')
        self.assertTrue(foreign.exists(), 'matrix row deleted another run\'s scratch')

    def test_fixture_scratch_is_outside_checkout(self):
        self.assertNotIn(ROOT, self.base.parents)

    def test_local_key_never_enters_curl_argv_and_header_is_private_and_removed(self):
        engine = (SCRIPTS / 'outsourcerer.sh').read_text()
        functions = '\n'.join(re.search(r'^' + name + r'\(\) \{.*?^}', engine, re.M | re.S).group()
                              for name in ('_curl_with_auth', 'delegate_local'))
        bindir = self.base / 'bin'
        bindir.mkdir()
        curl = bindir / 'curl'
        curl.write_text('''#!/usr/bin/python3
import json, os, pathlib, stat, sys
args = sys.argv[1:]
header = next((args[i+1][1:] for i, arg in enumerate(args[:-1]) if arg == '-H' and args[i+1].startswith('@')), None)
row = dict(argv=args, header_file=header)
if header:
 path = pathlib.Path(header)
 row.update(header=path.read_text(), mode=stat.S_IMODE(path.stat().st_mode))
pathlib.Path(os.environ['CURL_CAPTURE']).write_text(json.dumps(row))
if os.environ['CURL_RC'] != '0': sys.exit(int(os.environ['CURL_RC']))
print('data: {"choices":[{"delta":{"content":"fixture-output"}}]}')
print('data: [DONE]')
''')
        curl.chmod(0o755)
        driver = self.base / 'local.sh'
        driver.write_text(functions + '''
have() { command -v "$1" >/dev/null; }
die() { printf "%s\\n" "$*" >&2; exit 1; }
_local_resolve() { printf 'http://127.0.0.1/v1|fixture'; }
_with_preamble_render() { :; }
resolve_tier() { printf fixture; }
_build_prompt() { printf fixture-prompt; }
_tier_banner() { :; }
_lane_cost_disclosure() { printf fixture; }
record_ledger() { :; }
MODEL=fixture
REST=(fixture-task)
delegate_local auto
''')
        capture = self.base / 'curl.json'
        key = 'synthetic-local-key-canary'
        for rc in ('0', '22'):
            with self.subTest(curl_rc=rc):
                env = dict(self.env, PATH=str(bindir) + ':' + os.environ['PATH'], OSRC_LOCAL_KEY=key,
                           OSRC_LOCAL_AGENTIC='0', OSRC_STREAM='0', CURL_CAPTURE=str(capture), CURL_RC=rc)
                result = subprocess.run(['/bin/bash', str(driver)], env=env, capture_output=True, text=True)
                row = json.loads(capture.read_text())
                self.assertNotIn(key, '\0'.join(row['argv']))
                self.assertEqual(row['header'], 'Authorization: Bearer ' + key + '\n')
                self.assertEqual(row['mode'], 0o600)
                self.assertFalse(Path(row['header_file']).exists(), 'credential header leaked after curl returned')
                if rc == '0':
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('fixture-output', result.stdout)
                else:
                    self.assertNotEqual(result.returncode, 0)

    def test_matrix_accepts_output_directory(self):
        result = subprocess.run(['python3', str(ROOT / 'scripts/sealed_host_matrix.py'),
                                 '--list', '--out', str(self.base / 'proof'),
                                 '--suite', 'test_done_contract', '--mode', 'sealed'],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_matrix_runtime_scratch_stays_outside_checkout(self):
        with mock.patch.dict(os.environ, {'TMPDIR': str(ROOT)}), \
                mock.patch.object(tempfile, 'gettempdir', return_value=str(ROOT)):
            with matrix.suite_scratch() as scratch:
                self.assertNotIn(ROOT, Path(scratch).resolve().parents)
                self.assertNotEqual(ROOT, Path(scratch).resolve())

    def test_direct_guard_blocks_absolute_agent_paths(self):
        fake = self.base / 'claude'
        fake.write_text('#!/bin/sh\necho REAL-AGENT-RAN\n')
        fake.chmod(0o755)
        bindir = self.base / 'bin'
        bindir.mkdir()
        command = matrix.direct_command([str(fake)], bindir, agent_paths=[fake])
        # Check the sandbox boundary argv/profile here. The host probe executes it.
        self.assertNotEqual(command, [str(fake)])
        if os.uname().sysname == 'Darwin':
            self.assertIn(str(fake), (bindir / 'direct.sb').read_text())

    def test_linux_network_probe_requires_private_interfaces_and_no_route(self):
        import errno, socket, sys
        tree = ast.parse((SCRIPTS / 'tests/test_sealed_runner.py').read_text())
        probe = next(node.args[0].value for node in ast.walk(tree)
                     if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                     and isinstance(node.func.value, ast.Name) and node.func.value.id == 'py'
                     and node.func.attr == 'write_text')
        start = next(node.lineno for node in ast.parse(probe).body
                     if any(isinstance(item, ast.Call) and isinstance(item.func, ast.Attribute)
                            and isinstance(item.func.value, ast.Name) and item.func.value.id == 'socket'
                            for item in ast.walk(node)))
        network = '\n'.join(probe.splitlines()[start - 1:])
        for route_error in (errno.ENETUNREACH, errno.EHOSTUNREACH, errno.ECONNREFUSED, errno.EPERM, None):
            for names in ([(1, 'lo')], [(1, 'lo'), (2, 'eth0')]):
                with self.subTest(route_error=route_error, interfaces=names):
                    client = mock.Mock()
                    def connect(target):
                        # Loopback refusal carries no isolation evidence.
                        code = errno.ECONNREFUSED if target[0] == '127.0.0.1' else route_error
                        if code is not None:
                            raise OSError(code, 'fixture network result')
                    client.connect.side_effect = connect
                    scope = dict(errno=errno, socket=socket, sys=sys)
                    with mock.patch.object(sys, 'platform', 'linux'), \
                            mock.patch.object(socket, 'if_nameindex', return_value=names), \
                            mock.patch.object(socket, 'socket', return_value=client), mock.patch('sys.stdout'):
                        if len(names) > 1:
                            with self.assertRaisesRegex(SystemExit, 'non-loopback interface visible'):
                                exec(compile(network, 'network-probe', 'exec'), scope)
                            client.connect.assert_not_called()
                        elif route_error in (errno.ENETUNREACH, errno.EHOSTUNREACH):
                            exec(compile(network, 'network-probe', 'exec'), scope)
                        elif route_error is None:
                            with self.assertRaisesRegex(SystemExit, 'network allowed'):
                                exec(compile(network, 'network-probe', 'exec'), scope)
                        else:
                            with self.assertRaises(OSError) as caught:
                                exec(compile(network, 'network-probe', 'exec'), scope)
                            self.assertEqual(caught.exception.errno, route_error)
                    if len(names) == 1:
                        client.connect.assert_called_once_with(('1.1.1.1', 53))

    def test_linux_runtime_requires_a_successful_process_probe(self):
        def run(args, **kwargs):
            if str(args[-1]).endswith('process.sh'):
                return SimpleNamespace(returncode=77, stdout='', stderr='requires process-inspection')
            return SimpleNamespace(returncode=0, stdout='shell scratch isolated\nisolated\n', stderr='')
        with mock.patch.object(runner_tests.sys, 'platform', 'linux'), \
                mock.patch.dict(os.environ, {'CI': 'true'}), \
                mock.patch.object(runner_tests.os, 'access', return_value=True), \
                mock.patch.object(runner_tests.subprocess, 'run', side_effect=run):
            result = unittest.TestResult()
            runner_tests.SealedRunnerTests('test_isolation_probes').run(result)
        self.assertTrue(result.failures, 'broken Linux process probe was accepted as unsupported')

if __name__ == '__main__':
    unittest.main(verbosity=2)
