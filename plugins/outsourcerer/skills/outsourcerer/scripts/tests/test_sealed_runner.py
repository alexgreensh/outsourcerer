#!/usr/bin/env python3
"""Focused classifier and sandbox boundary checks; all scratch stays in the worktree."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = Path(subprocess.check_output(['git', '-C', str(SCRIPTS), 'rev-parse', '--show-toplevel'], text=True).strip()).resolve()
REL = SCRIPTS.relative_to(ROOT)
sys.path.insert(0, str(SCRIPTS / 'lib'))
spec = importlib.util.spec_from_file_location('approver_classify', SCRIPTS / 'lib/approver_classify.py')
classifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(classifier)


class SealedRunnerTests(unittest.TestCase):
    def test_each_classifier_guard_rejects_a_mutant(self):
        original = classifier.sealed_runner
        runner = str(REL / 'sealed-run.sh')
        test = str(REL / 'tests/test_approver_table.sh')
        good = runner + ' ' + test
        mutants = {
            'pipe': lambda c: '| cat' in c,
            'environment': lambda c: c.startswith('CI=1 '),
            'parent path': lambda c: '../' in c,
            'runner identity': lambda c: c.startswith('/elsewhere/'),
            'extra argument': lambda c: c.endswith('--help'),
            'symlink escape': lambda c: c.endswith('/outside.sh'),
            'missing tool': lambda c: c == good,
        }
        for name, permits in mutants.items():
            with self.subTest(guard=name):
                with mock.patch.object(classifier, 'sealed_runner', side_effect=lambda c, cwd, root: original(c, cwd, root) or permits(c)):
                    outcome = unittest.TestResult()
                    SealedRunnerTests('test_exact_command_and_rejections').run(outcome)
                    self.assertTrue(outcome.failures or outcome.errors, name + ' mutant survived')

    def test_approval_summary_counts_new_approvals(self):
        rows = '11\t1\tapproved\tone\tdetail\tnext\n1\t2\tapproval\ttwo\tdetail\tnext\n11\t3\tapproved\tthree\tdetail\tnext'
        result = subprocess.run(['/bin/bash', '-c', '. "$1"; _sv_approval_summary "$2"', 'bash', str(SCRIPTS / 'lib/supervise.sh'), rows], capture_output=True, text=True, check=True)
        self.assertIn('2 auto-approval(s)', result.stderr)
        self.assertIn(os.environ['OSRC_HOME'] + '/approvals.log', result.stderr)
        quiet = subprocess.run(['/bin/bash', '-c', '. "$1"; _sv_approval_summary "$2"', 'bash', str(SCRIPTS / 'lib/supervise.sh'), '1\t2\tapproval\ttwo'], capture_output=True, text=True, check=True)
        self.assertEqual(quiet.stderr, '')

    def test_recursive_remove_in_worktree_is_held(self):
        for command in ['rm -rf plugins', 'rm --recursive plugins', 'rm -r plugins']:
            with self.subTest(command=command):
                self.assertFalse(classifier.is_safe(command, 'shell', '', str(ROOT), [str(ROOT)])[0])

    def test_exact_command_and_rejections(self):
        runner = str(REL / 'sealed-run.sh')
        test = str(REL / 'tests/test_approver_table.sh')
        good = runner + ' ' + test
        with mock.patch.object(classifier.os, 'access', return_value=True):
            self.assertTrue(classifier.is_safe(good, 'shell', '', str(ROOT), [str(ROOT)])[0])
            for bad in [good + ' | cat', good + '; echo x', good + ' > /dev/null',
                        'CI=1 ' + good, runner + ' ../' + test,
                        '/elsewhere/sealed-run.sh ' + test, good + ' --help', good + '\nls']:
                with self.subTest(command=bad):
                    self.assertFalse(classifier.is_safe(bad, 'shell', '', str(ROOT), [str(ROOT)])[0])
            with tempfile.TemporaryDirectory(prefix='.sealed-link-', dir=str(SCRIPTS / 'tests')) as d:
                link = Path(d) / 'outside.sh'
                link.symlink_to('/etc/hosts')
                self.assertFalse(classifier.is_safe(runner + ' ' + str(link.relative_to(ROOT)), 'shell', '', str(ROOT), [str(ROOT)])[0])
        real_access = os.access
        with mock.patch.object(classifier.os, 'access', side_effect=lambda path, mode: False if str(path) in ('/usr/bin/bwrap', '/usr/bin/sandbox-exec') else real_access(path, mode)):
            self.assertFalse(classifier.is_safe(good, 'shell', '', str(ROOT), [str(ROOT)])[0])

    def test_isolation_probes(self):
        tool = '/usr/bin/sandbox-exec' if sys.platform == 'darwin' else '/usr/bin/bwrap'
        if not os.access(tool, os.X_OK):
            self.skipTest('OS isolation tool unavailable')
        with tempfile.TemporaryDirectory(prefix='.sealed-proof-', dir=str(ROOT)) as temp:
            home = Path(temp) / 'home'
            root = home / 'project'
            scripts = root / REL
            (scripts / 'tests').mkdir(parents=True)
            shutil.copy2(SCRIPTS / 'sealed-run.sh', scripts / 'sealed-run.sh')
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            secret = home / 'secret'; secret.write_text('not a credential')
            outside = home / 'outside'
            py = scripts / 'tests/probe.py'
            py.write_text('''import errno, pathlib, socket, sys\nsecret, outside = sys.argv[1:]\ntry:\n pathlib.Path(secret).read_text(); raise SystemExit("secret read allowed")\nexcept PermissionError: pass\ntry:\n pathlib.Path(outside).write_text("bad"); raise SystemExit("outside write allowed")\nexcept PermissionError: pass\ns=socket.socket()\ntry:\n s.connect(("127.0.0.1", 9)); raise SystemExit("network allowed")\nexcept OSError as e:\n if e.errno not in (errno.EPERM, errno.EACCES): raise\nprint("isolated")\n''')
            sh = scripts / 'tests/probe.sh'
            sh.write_text('#!/bin/bash\nexec /usr/bin/python3 "' + str(py) + '" "' + str(secret) + '" "' + str(outside) + '"\n')
            env = dict(os.environ, HOME=str(home), OSRC_HOME=str(home / 'osrc'))
            result = subprocess.run([str(scripts / 'sealed-run.sh'), str((REL / 'tests/probe.sh'))], cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if 'sandbox_apply: Operation not permitted' in result.stderr:
                self.skipTest('nested macOS sandbox is unavailable: sandbox_apply denied')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('isolated', result.stdout)
            self.assertFalse(outside.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
