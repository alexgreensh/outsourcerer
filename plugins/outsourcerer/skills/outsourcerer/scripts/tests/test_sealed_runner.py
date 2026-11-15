#!/usr/bin/env python3
"""Focused classifier and sandbox boundary checks; all scratch stays in the worktree."""
import importlib.util
import io
import os
from pathlib import Path
import pwd
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest
import uuid
from types import SimpleNamespace
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = Path(subprocess.check_output(['git', '-C', str(SCRIPTS), 'rev-parse', '--show-toplevel'], text=True).strip()).resolve()
REL = SCRIPTS.relative_to(ROOT)
sys.path.insert(0, str(SCRIPTS / 'lib'))
spec = importlib.util.spec_from_file_location('approver_classify', SCRIPTS / 'lib/approver_classify.py')
classifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(classifier)


class SealedRunnerTests(unittest.TestCase):
    def test_unavailable_host_asserts_hold_without_running_tests(self):
        checks = []
        def run(args, **kwargs):
            if args[0] == 'git' or args[:2] == ['/bin/bash', '-n']:
                return SimpleNamespace(returncode=0, stdout='', stderr='')
            self.assertIn('--check-sandbox', args, 'worktree test ran on an unavailable host')
            checks.append(args)
            return SimpleNamespace(returncode=78, stdout='', stderr='sealed-run: OS isolation unavailable; runtime launch failed\n')
        with mock.patch.object(sys, 'platform', 'darwin'), mock.patch.dict(os.environ, {'CI': 'true'}), mock.patch.object(os, 'access', return_value=True), mock.patch.object(subprocess, 'run', side_effect=run), mock.patch.object(sys, 'stdout', new_callable=io.StringIO) as output:
            outcome = unittest.TestResult(); SealedRunnerTests('test_isolation_probes').run(outcome)
        self.assertFalse(outcome.failures or outcome.errors, str(outcome.failures + outcome.errors))
        self.assertFalse(outcome.skipped, 'unavailable host must prove a classifier hold')
        self.assertGreaterEqual(len(checks), 2, 'availability and classifier must both check the real runner')
        self.assertIn('HOLD branch', output.getvalue())

    def test_plain_mac_requires_positive_isolation_and_reports_branch(self):
        for available in (False, True):
            def run(args, **kwargs):
                if args[0] == 'git': return SimpleNamespace(returncode=0, stdout='', stderr='')
                if not available:
                    return SimpleNamespace(returncode=78, stdout='', stderr='sealed-run: OS isolation unavailable\n')
                return SimpleNamespace(returncode=0, stdout='shell scratch isolated\nisolated\n', stderr='')
            with self.subTest(available=available), mock.patch.object(sys, 'platform', 'darwin'), \
                    mock.patch.dict(os.environ), mock.patch.object(os, 'access', return_value=True), \
                    mock.patch.object(subprocess, 'run', side_effect=run), mock.patch.object(sys, 'stdout', new_callable=io.StringIO) as output:
                os.environ.pop('CI', None)
                outcome = unittest.TestResult(); SealedRunnerTests('test_isolation_probes').run(outcome)
                self.assertFalse(outcome.skipped)
                if available:
                    self.assertFalse(outcome.failures or outcome.errors, str(outcome.failures + outcome.errors))
                else:
                    self.assertTrue(outcome.failures, 'plain Mac silently accepted unavailable isolation')
                self.assertIn('isolation branch', output.getvalue())

    def test_runner_statuses_flag_orders_and_reserved_exit(self):
        with tempfile.TemporaryDirectory(prefix='.runner-contract-', dir=ROOT) as d:
            root = Path(d); tests = root / REL / 'tests'; tests.mkdir(parents=True)
            subprocess.run(['git', 'init', '-q', d], check=True)
            test = tests / 'reserved.sh'; test.write_text('exit 78\n')
            process_test = tests / 'process.sh'
            process_test.write_text('#!/bin/bash\n# sealed-run-requires: process-inspection\necho must-not-run\n')
            backend = root / 'sandbox-exec'
            backend.write_text('''#!/bin/sh
shift 2
for argument in "$@"; do
  case "$argument" in PATH=*) copied="${argument#PATH=}"; copied="${copied%%:*}/ps" ;; esac
done
[ -x "$copied" ] && [ ! -u "$copied" ] && [ ! -g "$copied" ] || exit 96
case " $* " in *sealed-process-probe*) exit 86 ;; esac
exec "$@"
'''); backend.chmod(0o755)
            source = (SCRIPTS / 'sealed-run.sh').read_text()
            query = '$(/usr/bin/env -u DEVELOPER_DIR /usr/bin/xcode-select -p 2>/dev/null)'
            mac = source.replace('case "$(uname -s)" in', 'case Darwin in').replace('Darwin) [ -x /usr/bin/sandbox-exec ] && isolation=mac ;;', 'Darwin) isolation=mac ;;')
            mac = mac.replace('/usr/bin/sandbox-exec -f', shlex.quote(str(backend)) + ' -f')
            good = mac.replace(query, '$(printf /Library/Developer/CommandLineTools)')
            none = source.replace('case "$(uname -s)" in', 'case NoOS in')
            cases = [
                ('xcode-select failure', mac.replace(query, '$(exit 71)'), ['--check-sandbox'], 78),
                ('profile failure', good.replace('import json, os, sys\n', 'import json, os, sys\nraise OSError("profile failed")\n'), ['--check-sandbox'], 78),
                ('manual then check, no OS', none, ['--allow-unisolated', '--check-sandbox'], 78),
                ('check then manual, no OS', none, ['--check-sandbox', '--allow-unisolated'], 78),
                ('manual then check, working OS', good, ['--allow-unisolated', '--check-sandbox'], 0),
                ('check then manual, working OS', good, ['--check-sandbox', '--allow-unisolated'], 0),
                ('test exit 78', good, [str(test.relative_to(root))], 1),
                ('process inspection unavailable', good, [str(process_test.relative_to(root))], 77),
            ]
            runner = root / 'runner.sh'
            for label, content, args, expected in cases:
                with self.subTest(case=label):
                    runner.write_text(content)
                    result = subprocess.run(['/bin/bash', '-p', str(runner)] + args, cwd=root,
                                            env=dict(os.environ, HOME=d, OSRC_HOME=str(root / 'osrc')), capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                    if label in ('xcode-select failure', 'profile failure'):
                        self.assertIn('OS isolation unavailable', result.stderr)
                    if label == 'process inspection unavailable':
                        self.assertIn('requires process-inspection', result.stderr)
                        self.assertNotIn('must-not-run', result.stdout)

    def test_check_mode_has_no_dead_true_entry(self):
        self.assertNotIn('tests=(/usr/bin/true)', (SCRIPTS / 'sealed-run.sh').read_text())

    def test_denied_suite_capability_is_named_before_execution(self):
        with tempfile.TemporaryDirectory(prefix='.capability-proof-', dir=ROOT) as d:
            root = Path(d); tests = root / REL / 'tests'; tests.mkdir(parents=True)
            subprocess.run(['git', 'init', '-q', d], check=True)
            test = tests / 'needs-network.sh'
            test.write_text('#!/bin/bash\n# sealed-run-requires: network\necho must-not-run\n')
            result = subprocess.run(['/bin/bash', '-p', str(SCRIPTS / 'sealed-run.sh'), str(test.relative_to(root))],
                                    cwd=root, env=dict(os.environ, HOME=d, OSRC_HOME=str(root / 'osrc')),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
            self.assertIn('unsupported suite: requires network', result.stderr)
            self.assertNotIn('must-not-run', result.stdout)

    def test_network_suites_refuse_before_launch(self):
        for name in ('test_hub.sh', 'test_hub_home.sh', 'test_grokbot_lane.sh'):
            with self.subTest(suite=name):
                result = subprocess.run(['/bin/bash', '-p', str(SCRIPTS / 'sealed-run.sh'),
                                         str(REL / 'tests' / name)], cwd=ROOT,
                                        env=dict(os.environ, OSRC_HOME=os.environ['OSRC_HOME']),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
                self.assertIn('unsupported suite: requires network', result.stderr)
                self.assertNotIn('sandbox-exec:', result.stderr)

    def test_shell_bootstrap_uses_scratch_before_here_document(self):
        import re
        source = (SCRIPTS / 'sealed-run.sh').read_text()
        script = re.search(r"/bin/bash -p -c '([^']*)' sealed-run", source).group(1)
        with tempfile.TemporaryDirectory(prefix='.shell-bootstrap-', dir=ROOT) as d:
            result = subprocess.run(['/bin/bash', '-p', '-c', script, 'sealed-run', '/bin/pwd', '-P'],
                                    cwd=ROOT, env=dict(os.environ, TMPDIR=d), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.strip(), str(Path(d).resolve()))

    def test_working_sandbox_still_rejects_an_isolation_failure(self):
        def run(args, **kwargs):
            if args[0] == 'git' or '--check-sandbox' in args:
                return SimpleNamespace(returncode=0, stdout='', stderr='')
            return SimpleNamespace(returncode=1, stdout='', stderr='outside write allowed')
        with mock.patch.object(sys, 'platform', 'darwin'), mock.patch.object(os, 'access', return_value=True), mock.patch.object(subprocess, 'run', side_effect=run), mock.patch.object(sys, 'stdout', new_callable=io.StringIO):
            outcome = unittest.TestResult(); SealedRunnerTests('test_isolation_probes').run(outcome)
        self.assertTrue(outcome.failures)
        self.assertFalse(outcome.skipped)

    def test_unavailable_classifier_approval_mutant_is_rejected(self):
        with mock.patch.object(classifier, 'sealed_runner', return_value=True):
            outcome = unittest.TestResult(); SealedRunnerTests('test_unavailable_host_asserts_hold_without_running_tests').run(outcome)
        self.assertTrue(outcome.failures, 'unavailable runtime was auto-approved')

    def test_priority_failure_does_not_abort_or_hide_test_exit(self):
        source = (SCRIPTS / 'sealed-run.sh').read_text()
        import re
        match = re.search(r"/bin/bash -p -c '([^']*)' sealed-run", source)
        self.assertIsNotNone(match, 'priority must be best effort inside the launcher')
        with tempfile.TemporaryDirectory(prefix='.priority-proof-', dir=ROOT) as d:
            stub = Path(d) / 'renice'; marker = Path(d) / 'called'
            stub.write_text('#!/bin/sh\nprintf called > ' + shlex.quote(str(marker)) + '\nexit 71\n'); stub.chmod(0o755)
            script = match.group(1).replace('/usr/bin/renice', '"$OSRC_TEST_PRIORITY"')
            result = subprocess.run(['/bin/bash', '-p', '-c', script, 'sealed-run', '/bin/sh', '-c', 'echo test-ran; exit 23'],
                                    env=dict(os.environ, OSRC_TEST_PRIORITY=str(stub)), capture_output=True, text=True)
            self.assertTrue(marker.exists())
            self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
            self.assertIn('test-ran', result.stdout)

    def test_runner_reports_runtime_unavailable_before_worktree_execution(self):
        with tempfile.TemporaryDirectory(prefix='.runtime-proof-', dir=ROOT) as d:
            root = Path(d); tests = root / REL / 'tests'; tests.mkdir(parents=True)
            subprocess.run(['git', 'init', '-q', d], check=True)
            test = tests / 'probe.sh'; test.write_text('echo must-not-run\n')
            stub = root / 'sandbox-exec'; calls = root / 'calls'
            stub.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> ' + shlex.quote(str(calls)) + '''
case " $* " in *"/usr/bin/python3 -I -c"*) echo 'runtime cannot start' >&2; exit 71 ;; esac
exit 0
'''); stub.chmod(0o755)
            runner = root / 'sealed-run.sh'; source = (SCRIPTS / 'sealed-run.sh').read_text()
            source = source.replace('case "$(uname -s)" in', 'case Darwin in')
            source = source.replace('Darwin) [ -x /usr/bin/sandbox-exec ] && isolation=mac ;;', 'Darwin) isolation=mac ;;')
            source = source.replace('$(/usr/bin/env -u DEVELOPER_DIR /usr/bin/xcode-select -p 2>/dev/null)', '$(printf /Library/Developer/CommandLineTools)')
            source = source.replace('/usr/bin/sandbox-exec -f', shlex.quote(str(stub)) + ' -f')
            runner.write_text(source)
            for args in [ ['--check-sandbox'], [str(test.relative_to(root))] ]:
                with self.subTest(args=args):
                    result = subprocess.run(['/bin/bash', '-p', str(runner)] + args, cwd=root,
                                            env=dict(os.environ, HOME=d, OSRC_HOME=str(root / 'osrc')), capture_output=True, text=True)
                    self.assertEqual(result.returncode, 78, result.stdout + result.stderr)
                    self.assertIn('sealed-run: OS isolation unavailable', result.stderr)
            self.assertNotIn(str(test), calls.read_text())

    def test_trust_guard_mutant_is_rejected(self):
        with mock.patch.object(classifier, 'trusted_sealed_runner', return_value=True):
            outcome = unittest.TestResult()
            SealedRunnerTests('test_installed_runner_must_be_immutable_to_delegate').run(outcome)
            self.assertTrue(outcome.failures or outcome.errors)

    def test_installed_runner_must_be_immutable_to_delegate(self):
        safe = SimpleNamespace(st_uid=0, st_mode=0o755)
        with mock.patch.object(classifier.os, 'geteuid', return_value=501), mock.patch.object(classifier.os, 'stat', return_value=safe), mock.patch.object(classifier.os, 'access', return_value=False):
            self.assertTrue(classifier.trusted_sealed_runner('/trusted/sealed-run.sh'))
        for unsafe in [SimpleNamespace(st_uid=501, st_mode=0o755), SimpleNamespace(st_uid=0, st_mode=0o775)]:
            with self.subTest(mode=unsafe.st_mode, owner=unsafe.st_uid), mock.patch.object(classifier.os, 'geteuid', return_value=501), mock.patch.object(classifier.os, 'stat', return_value=unsafe), mock.patch.object(classifier.os, 'access', return_value=False):
                self.assertFalse(classifier.trusted_sealed_runner('/trusted/sealed-run.sh'))
        with mock.patch.object(classifier.os, 'geteuid', return_value=501), mock.patch.object(classifier.os, 'stat', return_value=safe), mock.patch.object(classifier.os, 'access', return_value=True):
            self.assertFalse(classifier.trusted_sealed_runner('/trusted/sealed-run.sh'))
        with mock.patch.object(classifier.os, 'geteuid', return_value=0):
            self.assertFalse(classifier.trusted_sealed_runner('/trusted/sealed-run.sh'))

    def test_untrusted_replacement_runner_is_held(self):
        self.assertFalse(classifier.trusted_sealed_runner(str(SCRIPTS / 'sealed-run.sh')))
        with tempfile.TemporaryDirectory(prefix='.sealed-untrusted-', dir=str(ROOT)) as d:
            root = Path(d)
            scripts = root / REL
            (scripts / 'tests').mkdir(parents=True)
            runner = scripts / 'sealed-run.sh'
            runner.write_text('#!/bin/sh\nexit 0\n'); runner.chmod(0o755)
            (scripts / 'tests/test_example.sh').write_text('#!/bin/sh\nexit 0\n')
            cmd = str(REL / 'sealed-run.sh') + ' ' + str(REL / 'tests/test_example.sh')
            with mock.patch.object(classifier.os, 'access', return_value=True):
                self.assertFalse(classifier.is_safe(cmd, 'shell', '', str(root), [str(root)])[0])

    def test_each_classifier_guard_rejects_a_mutant(self):
        original = classifier.sealed_runner
        runner = shlex.quote(str(SCRIPTS / 'sealed-run.sh'))
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
        runner = shlex.quote(str(SCRIPTS / 'sealed-run.sh'))
        test = str(REL / 'tests/test_approver_table.sh')
        good = runner + ' ' + test
        with mock.patch.object(classifier.os, 'access', return_value=True), mock.patch.object(classifier, 'trusted_sealed_runner', return_value=True), mock.patch.object(classifier.subprocess, 'run', return_value=SimpleNamespace(returncode=0)):
            self.assertTrue(classifier.sealed_runner(good, str(ROOT), str(ROOT)))
            self.assertTrue(classifier.is_safe(good, 'shell', '', str(ROOT), [str(ROOT)])[0])
            for bad in [good + ' | cat', good + '; echo x', good + ' > /dev/null',
                        'CI=1 ' + good, runner + ' ../' + test,
                        '/elsewhere/sealed-run.sh ' + test, good + ' --help', good + '\nls']:
                with self.subTest(command=bad):
                    self.assertFalse(classifier.sealed_runner(bad, str(ROOT), str(ROOT)))
            with tempfile.TemporaryDirectory(prefix='.sealed-link-', dir=str(SCRIPTS / 'tests')) as d:
                link = Path(d) / 'outside.sh'
                link.symlink_to('/etc/hosts')
                self.assertFalse(classifier.sealed_runner(runner + ' ' + str(link.relative_to(ROOT)), str(ROOT), str(ROOT)))
        real_access = os.access
        with mock.patch.object(classifier.os, 'access', side_effect=lambda path, mode: False if str(path) in ('/usr/bin/bwrap', '/usr/bin/sandbox-exec') else real_access(path, mode)), mock.patch.object(classifier, 'trusted_sealed_runner', return_value=True):
            self.assertFalse(classifier.sealed_runner(good, str(ROOT), str(ROOT)))
            with mock.patch.object(classifier.sys, 'platform', 'linux'):
                self.assertFalse(classifier.sealed_runner(good, str(ROOT), str(ROOT)))

    def test_isolation_probes(self):
        require_isolation = (sys.platform == 'darwin' and not os.environ.get('CI')) or (sys.platform == 'linux' and os.environ.get('CI', '').lower() == 'true')
        tool = '/usr/bin/sandbox-exec' if sys.platform == 'darwin' else '/usr/bin/bwrap'
        if not os.access(tool, os.X_OK):
            if require_isolation:
                print('test_isolation_probes: isolation branch (required)', flush=True)
                self.fail('working OS sandbox required for runtime proof')
            print('test_isolation_probes: HOLD branch', flush=True)
            cmd = shlex.quote(str(SCRIPTS / 'sealed-run.sh')) + ' ' + str(REL / 'tests/test_approver_table.sh')
            with mock.patch.object(classifier, 'trusted_sealed_runner', return_value=True):
                self.assertFalse(classifier.is_safe(cmd, 'shell', '', str(ROOT), [str(ROOT)])[0])
            return
        with tempfile.TemporaryDirectory(prefix='.sealed-proof-', dir=Path(os.environ.get('TMPDIR') or tempfile.gettempdir()).resolve()) as temp:
            home = Path(temp) / 'home'
            root = home / 'project'
            main = home / 'main'
            main.mkdir(parents=True)
            subprocess.run(['git', 'init', '-q', str(main)], check=True)
            subprocess.run(['git', '-C', str(main), '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid',
                            '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'fixture', '--allow-empty'], check=True)
            subprocess.run(['git', '-C', str(main), 'worktree', 'add', '-q', '--detach', str(root)], check=True)
            scripts = root / REL
            (scripts / 'tests').mkdir(parents=True)
            shutil.copy2(SCRIPTS / 'sealed-run.sh', scripts / 'sealed-run.sh')
            canary = root / 'read-only-canary'; canary.write_text('unchanged')
            secret = home / 'secret'; secret.write_text('not a credential')
            outside = home / 'outside'
            real_home_write = Path(pwd.getpwuid(os.getuid()).pw_dir) / ('.osrc-sealed-probe-' + uuid.uuid4().hex)
            py = scripts / 'tests/probe.py'
            py.write_text('''import errno, pathlib, socket, sys
secret, outside = sys.argv[1:]
try:
 pathlib.Path(secret).read_text(); raise SystemExit("secret read allowed")
except OSError as e:
 if e.errno not in (errno.EPERM, errno.EACCES, errno.ENOENT, errno.EROFS): raise
try:
 pathlib.Path(outside).write_text("bad"); raise SystemExit("outside write allowed")
except OSError as e:
 if e.errno not in (errno.EPERM, errno.EACCES, errno.ENOENT, errno.EROFS): raise
s=socket.socket()
try:
 s.connect(("127.0.0.1", 9)); raise SystemExit("network allowed")
except OSError as e:
 allowed = (errno.EPERM, errno.EACCES)
 if sys.platform == 'linux': allowed += (errno.ENETUNREACH, errno.ECONNREFUSED)
 if e.errno not in allowed: raise
print("isolated")
''')
            sh = scripts / 'tests/probe.sh'
            sh.write_text('''#!/bin/bash
set -eu
scratch="$(pwd -P)"
[ "$scratch" = "$TMPDIR" ]
cd ''' + shlex.quote(str(root)) + '''
[ -r ''' + shlex.quote(str(sh)) + ''' ]
git rev-parse --show-toplevel > "$TMPDIR/git-root"
[ "$(cat "$TMPDIR/git-root")" = ''' + shlex.quote(str(root)) + ''' ]
common="$(git rev-parse --git-common-dir)"
[ -r "$common/config" ]
if (printf bad > "$common/sealed-write-probe") 2>/dev/null; then
  echo 'git common write allowed'; exit 1
fi
if (printf bad > .sealed-write-probe) 2>/dev/null; then
  echo 'worktree write allowed'; exit 1
fi
exec 4< read-only-canary
if (printf bad > /dev/fd/4) 2>/dev/null; then
  echo 'read-only descriptor upgraded to write'; exit 1
fi
exec 4<&-
cd "$scratch"
printf 'pipe proof' | cat > "$TMPDIR/pipe-proof"
[ "$(cat "$TMPDIR/pipe-proof")" = 'pipe proof' ]
[ ! -u "$(command -v ps)" ]
[ ! -g "$(command -v ps)" ]
sleep 30 & child=$!
trap 'kill "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :' EXIT
ps -o pid=,ppid=,pgid=,lstart= -p "$child" > "$TMPDIR/process"
[ -s "$TMPDIR/process" ]
kill "$child"; wait "$child" 2>/dev/null || :
trap - EXIT
value="$(cat <<'PROBE'
shell-here-document
PROBE
)"
[ "$value" = shell-here-document ]
created="$(mktemp -d "$TMPDIR/mktemp.XXXXXX")"
[ -d "$created" ]
rmdir "$created"
exec 3<<'LARGE_HEREDOC'
''' + 'x' * 70000 + '''
LARGE_HEREDOC
/usr/bin/python3 -I -c 'import fcntl, os, pathlib, sys
if sys.platform == "darwin":
    name = fcntl.fcntl(3, 50, bytes(1024)).split(bytes([0]))[0].decode()
else:
    name = os.readlink("/proc/self/fd/3").removesuffix(" (deleted)")
scratch = pathlib.Path(os.environ["TMPDIR"]).resolve()
assert pathlib.Path(name).resolve().is_relative_to(scratch), name
assert len(os.read(3, 80000)) == 70001
print("large here-document scratch:", name)
'
if (printf bad > ''' + shlex.quote(str(real_home_write)) + ''') 2>/dev/null; then
  echo 'real HOME write allowed'; exit 1
fi
if (printf bad > /tmp/''' + uuid.uuid4().hex + ''') 2>/dev/null; then
  echo 'system temp write allowed'; exit 1
fi
printf 'shell scratch isolated\\n'
exec /usr/bin/python3 ''' + shlex.quote(str(py)) + ' ' + shlex.quote(str(secret)) + ' ' + shlex.quote(str(outside)) + '\n')
            env = dict(os.environ, HOME=str(home), OSRC_HOME=str(home / 'osrc'))
            available = subprocess.run([str(scripts / 'sealed-run.sh'), '--check-sandbox'], cwd=root, env=env, capture_output=True, text=True)
            if available.returncode != 0:
                if require_isolation:
                    print('test_isolation_probes: isolation branch (required)', flush=True)
                    self.fail('working OS sandbox required: ' + available.stdout + available.stderr)
                print('test_isolation_probes: HOLD branch', flush=True)
                self.assertEqual(available.returncode, 78, available.stdout + available.stderr)
                self.assertIn('sealed-run: OS isolation unavailable', available.stderr)
                cmd = shlex.quote(str(SCRIPTS / 'sealed-run.sh')) + ' ' + str(REL / 'tests/probe.sh')
                with mock.patch.object(classifier, 'trusted_sealed_runner', return_value=True):
                    self.assertFalse(classifier.is_safe(cmd, 'shell', '', str(root), [str(root)])[0])
                self.assertFalse(outside.exists())
                return
            syntax = subprocess.run(['/bin/bash', '-n', str(sh)], capture_output=True, text=True)
            self.assertEqual(syntax.returncode, 0, syntax.stdout + syntax.stderr)
            print('test_isolation_probes: isolation branch', flush=True)
            result = subprocess.run([str(scripts / 'sealed-run.sh'), str((REL / 'tests/probe.sh'))], cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('isolated', result.stdout)
            self.assertIn('shell scratch isolated', result.stdout)
            self.assertFalse((root / '.sealed-write-probe').exists())
            self.assertFalse(real_home_write.exists())
            self.assertEqual(canary.read_text(), 'unchanged')
            self.assertFalse((main / '.git/sealed-write-probe').exists())
            self.assertFalse(outside.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
