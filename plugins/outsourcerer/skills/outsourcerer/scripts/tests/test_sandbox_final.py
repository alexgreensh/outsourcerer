#!/usr/bin/env python3
"""Adversarial regressions for the sealed execution and final review boundaries."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = Path(subprocess.check_output(['git', '-C', str(SCRIPTS), 'rev-parse', '--show-toplevel'], text=True).strip())
REL = SCRIPTS.relative_to(ROOT)
RUNNER = SCRIPTS / 'sealed-run.sh'
REVIEW = SCRIPTS / 'lib/review.sh'
CONFORMANCE = SCRIPTS / 'tests/conformance.sh'
sys.path.insert(0, str(SCRIPTS / 'lib'))
spec = importlib.util.spec_from_file_location('boundary_classifier', SCRIPTS / 'lib/approver_classify.py')
classifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(classifier)


class SandboxFinal(unittest.TestCase):
    def test_python_startup_never_imports_worktree_or_pythonpath(self):
        with tempfile.TemporaryDirectory(prefix='.boundary-', dir=ROOT) as d:
            p = Path(d); root = p / 'project'; tests = root / REL / 'tests'
            tests.mkdir(parents=True)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            sh = tests / 'probe.sh'; sh.write_text('exit 0\n')
            poison = "open(%r, 'w').write('escaped')\n" % str(p / 'escaped')
            (root / 'json.py').write_text(poison)
            (root / 'os.py').write_text(poison)
            (p / 'sitecustomize.py').write_text(poison)
            env = dict(os.environ, HOME=str(p), OSRC_HOME=str(p / 'osrc'), PYTHONPATH=str(p))
            subprocess.run(['/bin/bash', '-p', str(RUNNER), str(sh.relative_to(root))],
                           cwd=root, env=env, capture_output=True, timeout=20)
            self.assertFalse((p / 'escaped').exists(), 'worktree code ran before isolation')

    def test_linux_profile_hides_host_runtime_and_processes(self):
        source = RUNNER.read_text()
        for flag in ['--unshare-pid', '--unshare-ipc', '--proc /proc', '--tmpfs /tmp', '--tmpfs /run', '--clearenv']:
            self.assertIn(flag, source)
        self.assertNotIn('--ro-bind / /', source)
        self.assertIn('--ro-bind "$t/bin/$v" "$exe"', source)

    def test_mac_loader_profile_is_narrow_and_bootable(self):
        source = RUNNER.read_text()
        self.assertIn('(allow file-read* (literal "/"))', source)
        self.assertIn('file-read* file-map-executable', source)
        self.assertNotIn('(allow file-read* (subpath "/"))', source)
        self.assertIn('(deny network*)', source)

    @unittest.skipUnless(sys.platform == 'linux' and os.access('/usr/bin/bwrap', os.X_OK), 'Linux bubblewrap runtime unavailable')
    def test_linux_runtime_boundaries(self):
        with tempfile.TemporaryDirectory(prefix='.linux-boundary-', dir=ROOT) as d:
            p = Path(d); root = p / 'project'; tests = root / REL / 'tests'; tests.mkdir(parents=True)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            secret = p / 'secret'; secret.write_text('host secret')
            # This fixture must live in host /tmp to test that the runtime mount hides sockets.
            socket_dir = tempfile.mkdtemp(prefix='osrc-test-L14b-socket-', dir='/tmp')
            endpoint = Path(socket_dir) / 'host.sock'
            listener = socket.socket(socket.AF_UNIX); listener.bind(str(endpoint)); listener.listen(1)
            child = subprocess.Popen(['/bin/sleep', '60'])
            try:
                # All attempted targets belong to this test; a regressed profile cannot hurt others.
                probe = tests / 'probe.py'
                probe.write_text('''import errno, os, pathlib, socket, subprocess, sys
secret, endpoint, hostpid = sys.argv[1:]; hostpid = int(hostpid)
assert not pathlib.Path(secret).exists(), 'host secret visible'
s = socket.socket(socket.AF_UNIX)
try:
 s.connect(endpoint)
except OSError as e:
 assert e.errno in (errno.ENOENT, errno.EACCES, errno.EPERM), e
else: raise AssertionError('host Unix socket reachable')
assert not pathlib.Path('/proc/%s/cmdline' % hostpid).exists(), 'host proc visible'
try: os.kill(hostpid, 0)
except ProcessLookupError: pass
else: raise AssertionError('host PID visible')
for exe in ['/usr/bin/tmux', '/bin/tmux']:
 if pathlib.Path(exe).exists():
  assert subprocess.run([exe, '-L', 'osrc-test-L14b', 'display-message']).returncode == 99, 'absolute tmux bypassed stub'
print('linux boundaries isolated')
''')
                test = tests / 'probe.sh'
                test.write_text('exec /usr/bin/python3 ' + ' '.join(map(shlex.quote, [str(probe), str(secret), str(endpoint), str(child.pid)])) + '\n')
                env = dict(os.environ, HOME=str(p), OSRC_HOME=str(p / 'osrc'))
                result = subprocess.run(['/bin/bash', '-p', str(RUNNER), str(test.relative_to(root))],
                                        cwd=root, env=env, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('linux boundaries isolated', result.stdout)
                self.assertIsNone(child.poll())
            finally:
                listener.close(); child.terminate(); child.wait()
                shutil.rmtree(socket_dir)

    def test_only_proven_sealed_runs_are_approved(self):
        cmd = str(SCRIPTS / 'sealed-run.sh') + ' ' + str(REL / 'tests/test_approver_table.sh')
        with mock.patch.object(classifier, 'trusted_sealed_runner', return_value=True), \
                mock.patch.object(classifier.os, 'access', return_value=True), \
                mock.patch.object(classifier.subprocess, 'run') as run:
            run.return_value.returncode = 0
            self.assertTrue(classifier.is_safe(cmd, 'shell', '', str(ROOT), [str(ROOT)])[0])
            self.assertIn('--check-sandbox', run.call_args.args[0])
            run.return_value.returncode = 1
            self.assertFalse(classifier.is_safe(cmd, 'shell', '', str(ROOT), [str(ROOT)])[0])
            run.side_effect = subprocess.TimeoutExpired('probe', 10)
            self.assertFalse(classifier.is_safe(cmd, 'shell', '', str(ROOT), [str(ROOT)])[0])
        for cmd in ['bash ' + str(REL / 'tests/test_approver_table.sh'), 'npm test', 'make test', 'python3 -m unittest', 'cargo test']:
            self.assertFalse(classifier.is_safe(cmd, 'shell', '', str(ROOT), [str(ROOT)])[0], cmd)

    def test_all_python_suites_registered_and_executed_as_python(self):
        source = CONFORMANCE.read_text()
        registry = '\n'.join(re.findall(r'^_PYTHON_SUITES=.*$', source, re.M))
        for path in (SCRIPTS / 'tests').glob('test_*.py'):
            self.assertIn(path.stem, registry)
        self.assertIn('*.py) exec python3 "$2"', source)
        self.assertIn('for _f in "$SCRIPT_DIR"/test_*.py', source)

    def test_python_suite_executes_in_bounded_runner(self):
        with tempfile.TemporaryDirectory(prefix='.python-suite-', dir=ROOT) as d:
            suite = Path(d) / 'fixture.py'
            suite.write_text('import os\nassert os.environ["HOME"] == os.path.join(os.environ["OSRC_HOME"], "home")\nprint("python suite executed")\nraise SystemExit(7)\n')
            shell = '''
for fn in _run_unit_suite_bounded; do
  eval "$(sed -n '/^'"${fn}"'() {/,/^}/p' "$1")"
done
OSRC_SUITE_TIMEOUT=0
_run_unit_suite_bounded "$2"
printf '%s\\n%s\\n' "$_suite_rc" "$_suite_out"
'''
            result = subprocess.run(['/bin/bash', '-c', shell, 'bash', str(CONFORMANCE), str(suite)],
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip(), '7\npython suite executed')

    def review(self, final=False, legacy=False, advance=False, moved=False):
        with tempfile.TemporaryDirectory(prefix='.final-review-', dir=ROOT) as d:
            p = Path(d); (p / 'review/items').mkdir(parents=True)
            head = 'b' * 40; id = 'L14b-bbbbbbb'
            item = {'id': id, 'lane': 'L14b', 'head': head, 'branch': 'feature', 'base': 'main',
                    'transport': 'git', 'url': str(ROOT), 'brief': '', 'state': 'inflight',
                    'stale': False, 'sha_reviewed': '', 'verdict': ''}
            if legacy:
                item.update(state='verdict', verdict='MERGE')
            (p / f'review/items/{id}.json').write_text(json.dumps(item))
            prior_id = 'L14b-aaaaaaa'; vf = p / f'review/{prior_id}.VERDICT'; vf.write_text('CHANGES\nfix it\n')
            prior = dict(item, id=prior_id, head='a' * 40, state='verdict', sha_reviewed='a' * 40,
                         verdict='CHANGES', verdict_ts=1, findings=str(vf))
            (p / f'review/items/{prior_id}.json').write_text(json.dumps(prior))
            shell = '''. "$1"
OSRC_HOME="$2"; export OSRC_HOME
_osrc_id_ok() { return 0; }
_osrc_now() { echo 100; }
_osrc_jq_set() { local p="$1"; shift; jq "$@" "$p" > "$p.new" && mv "$p.new" "$p"; }
if [ "$5" != legacy ]; then
  _osrc_review_write_brief "$3" "$4" >/dev/null || exit
  [ "$7" != moved ] || _osrc_jq_set "$OSRC_HOME/review/items/$3.json" '.review_scope_head="wrong-head"'
  printf 'MERGE\\n' > "$OSRC_HOME/review/$3.VERDICT"
  _osrc_review_ingest
fi
if [ "$6" = advance ]; then
  _osrc_review_write_brief "$3" >/dev/null || exit
  _osrc_jq_set "$OSRC_HOME/review/items/$3.json" '.state="inflight"'
  _osrc_review_ingest
fi
_osrc_review_verdict_for L14b bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
'''
            result = subprocess.run(['/bin/bash', '-c', shell, 'bash', str(REVIEW), d,
                                     id, 'final' if final else '', 'legacy' if legacy else '',
                                     'advance' if advance else '', 'moved' if moved else ''], capture_output=True, text=True, check=True)
            return result.stdout.strip(), json.loads((p / f'review/items/{id}.json').read_text())

    def test_incremental_merge_cannot_finish_lane(self):
        verdict, item = self.review()
        self.assertNotEqual(verdict, 'MERGE')
        self.assertEqual(item['state'], 'queued')
        self.assertTrue(item['needs_final'])

    def test_full_diff_merge_can_finish_lane(self):
        verdict, item = self.review(final=True)
        self.assertEqual(verdict, 'MERGE')
        self.assertEqual(item['review_scope'], 'full')
        self.assertEqual(item['review_scope_head'], item['head'])

    def test_legacy_merge_without_full_round_cannot_finish_lane(self):
        self.assertNotEqual(self.review(legacy=True)[0], 'MERGE')

    def test_incremental_success_automatically_requires_full_packet(self):
        verdict, item = self.review(advance=True)
        self.assertEqual(verdict, 'MERGE')
        self.assertEqual(item['review_scope'], 'full')

    def test_full_review_must_match_head(self):
        verdict, item = self.review(final=True, moved=True)
        self.assertNotEqual(verdict, 'MERGE')
        self.assertEqual(item['state'], 'queued')

    def test_regressions_kill_boundary_mutants(self):
        runner = RUNNER.read_text(); review = REVIEW.read_text(); conf = CONFORMANCE.read_text()
        cases = [
            ('startup isolation', 'RUNNER', runner.replace('cd / && ', '').replace('python3 -I ', 'python3 '),
             'test_python_startup_never_imports_worktree_or_pythonpath'),
            ('host sockets', 'RUNNER', runner.replace('--tmpfs /tmp', ''), 'test_linux_profile_hides_host_runtime_and_processes'),
            ('host pids', 'RUNNER', runner.replace('--unshare-pid', ''), 'test_linux_profile_hides_host_runtime_and_processes'),
            ('absolute agents', 'RUNNER', runner.replace('--ro-bind "$t/bin/$v" "$exe"', ''), 'test_linux_profile_hides_host_runtime_and_processes'),
            ('loader root', 'RUNNER', runner.replace('(allow file-read* (literal "/"))', ''), 'test_mac_loader_profile_is_narrow_and_bootable'),
            ('CI registration', 'CONFORMANCE', conf.replace('test_sealed_runner ', ''), 'test_all_python_suites_registered_and_executed_as_python'),
            ('Python execution', 'CONFORMANCE', conf.replace('*.py) exec python3 "$2"', '*.py) exec bash "$2"'), 'test_python_suite_executes_in_bounded_runner'),
            ('suite HOME', 'CONFORMANCE', conf.replace('HOME="$_home/home" OSRC_HOME=', 'OSRC_HOME='), 'test_python_suite_executes_in_bounded_runner'),
            ('incremental merge', 'REVIEW', review.replace('if [ "$first" = MERGE ] && {', 'if false && {'), 'test_incremental_merge_cannot_finish_lane'),
            ('legacy merge', 'REVIEW', review.replace('if [ "$(jq -r \'.verdict // ""\' "$p")" = MERGE ]; then', 'if false; then'), 'test_legacy_merge_without_full_round_cannot_finish_lane'),
        ]
        for name, binding, source, method in cases:
            with self.subTest(guard=name), tempfile.TemporaryDirectory(prefix='.boundary-mutant-', dir=ROOT) as d:
                original = globals()[binding].read_text()
                self.assertNotEqual(source, original, 'mutation target missing')
                mutant = Path(d) / 'mutant.sh'; mutant.write_text(source)
                with mock.patch.dict(globals(), {binding: mutant}):
                    outcome = unittest.TestResult(); SandboxFinal(method).run(outcome)
                self.assertTrue(outcome.failures or outcome.errors, name + ' mutant survived')

    def test_broken_probe_mutant_is_rejected(self):
        source = (SCRIPTS / 'lib/approver_classify.py').read_text()
        changes = [('return probe.returncode == 0', 'return True'),
                   ('if any(r.startswith("test/build") for r in rules):', 'if False:')]
        for before, after in changes:
            self.assertIn(before, source)
            with self.subTest(guard=before), tempfile.TemporaryDirectory(prefix='.probe-mutant-', dir=ROOT) as d:
                path = Path(d) / 'mutant.py'; path.write_text(source.replace(before, after))
                spec = importlib.util.spec_from_file_location('mutant_classifier', path)
                mutant = importlib.util.module_from_spec(spec); spec.loader.exec_module(mutant)
                mutant.__file__ = classifier.__file__
                with mock.patch.dict(globals(), {'classifier': mutant}):
                    outcome = unittest.TestResult(); SandboxFinal('test_only_proven_sealed_runs_are_approved').run(outcome)
                self.assertTrue(outcome.failures or outcome.errors, 'sandbox approval mutant survived')


if __name__ == '__main__':
    unittest.main(verbosity=2)
