#!/usr/bin/env python3
"""Regression checks that do not require launching an OS sandbox."""
import importlib.util
import ast
import os
from pathlib import Path
import shlex
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
        self.temp = tempfile.TemporaryDirectory(prefix='.sealed-fixes-', dir=ROOT)
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
        self.assertNotIn('MUST-NOT-RUN', result.stdout)

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

    def test_mac_profile_limits_sysctl_to_named_runtime_keys(self):
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
        self.assertNotIn('(allow sysctl-read)', result.stdout)
        self.assertIn('sysctl-name "hw.pagesize"', result.stdout)
        self.assertNotIn('sysctl-name "kern.proc', result.stdout)

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

    def test_matrix_timeout_terminates_then_kills_and_cleans_scratch(self):
        temp = self.base / 'tmp'
        temp.mkdir()
        script = self.base / 'wait.sh'
        script.write_text('trap "echo terminated; exit 0" TERM\nmkdir "$TMPDIR/.osrc-sealed.owned"\nwhile :; do sleep 1; done\n')
        output = self.base / 'output.log'
        env = dict(self.env, TMPDIR=str(temp))
        rc = matrix.run(['/bin/bash', str(script)], self.base, env, output, .3)
        self.assertEqual(rc, 124)
        self.assertIn('terminated', output.read_text())
        self.assertFalse(list(temp.glob('.osrc-sealed.*')))

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

    def test_network_probe_rejects_connection_refused_without_isolation(self):
        tree = ast.parse((SCRIPTS / 'tests/test_sealed_runner.py').read_text())
        probe = next(node.args[0].value for node in ast.walk(tree)
                     if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                     and isinstance(node.func.value, ast.Name) and node.func.value.id == 'py'
                     and node.func.attr == 'write_text')
        network = probe[probe.index('s=socket.socket()'):]
        stub = 'import errno, socket, sys\nsys.platform="linux"\nclass Socket:\n def connect(self, target): raise OSError(errno.ECONNREFUSED, "refused")\nsocket.socket=Socket\n'
        result = subprocess.run(['python3', '-c', stub + network], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, 'host loopback refusal counted as network isolation')

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

    def test_host_bisect_preparation_never_launches_a_sandbox(self):
        output = self.base / 'prepared'
        result = subprocess.run(['python3', str(ROOT / 'scripts/sealed_host_bisect.py'),
                                 '--prepare-only', '--out', str(output)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        proof = Path(result.stdout.strip().split('PROOF_DIR=')[1])
        import json
        rows = json.loads((proof / 'results.json').read_text())
        self.assertTrue(rows)
        self.assertTrue(all(row['rc'] is None for row in rows))
        self.assertFalse(list(proof.glob('*/output.log')), 'prepare mode ran a sandbox command')
        sources = {row['variant']: Path(row['prepared']).read_text() for row in rows}
        baseline = self.git('show', '11598a4:' + str(REL / 'sealed-run.sh')) + '\n'
        regression = self.git('show', '75302c2:' + str(REL / 'sealed-run.sh')) + '\n'
        self.assertEqual(sources['baseline-original'], baseline)
        self.assertEqual(sources['regression-original'], regression)
        self.assertEqual(sources['current-fixed'], self.source)
        hunks = json.loads((proof / 'hunks.json').read_text())
        for hunk in hunks:
            old, new = baseline.splitlines(keepends=True), regression.splitlines(keepends=True)
            removed, added = hunk['removed'].splitlines(keepends=True), hunk['added'].splitlines(keepends=True)
            a, b = hunk['old_start'] - 1, hunk['new_start'] - 1
            self.assertEqual(sources['apply-' + hunk['name']], ''.join(old[:a] + added + old[a + len(removed):]))
            self.assertEqual(sources['revert-' + hunk['name']], ''.join(new[:b] + removed + new[b + len(added):]))

    def test_host_bisect_requires_a_working_control_before_naming_a_hunk(self):
        spec = importlib.util.spec_from_file_location('bisect_probe', ROOT / 'scripts/sealed_host_bisect.py')
        probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(probe)
        rows = [dict(variant=name, input_tmpdir='normal', rc=rc)
                for name, rc in [('baseline-original', 0), ('regression-original', 78),
                                 ('revert-hunk-02', 0), ('apply-hunk-02', 78)]]
        notes = probe.diagnosis(rows)
        self.assertIn('normal: reverting hunk-02 repairs startup; applying it alone rc=78', notes)
        rows[0]['rc'] = 78
        notes = probe.diagnosis(rows)
        self.assertIn('normal: invalid control, baseline did not pass', notes)
        self.assertFalse(any('repairs startup' in note for note in notes))


if __name__ == '__main__':
    unittest.main(verbosity=2)
