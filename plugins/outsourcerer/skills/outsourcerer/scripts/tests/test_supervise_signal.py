#!/usr/bin/env python3
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'outsourcerer.sh'
ROOT = Path(subprocess.check_output(['git', '-C', str(SCRIPT.parent), 'rev-parse', '--show-toplevel'], text=True).strip())


class SuperviseSignal(unittest.TestCase):
    def test_old_signal_handler_is_caught(self):
        with tempfile.TemporaryDirectory(prefix='.signal-mutant-', dir=str(ROOT)) as d:
            scripts = Path(d) / 'scripts'; scripts.mkdir()
            shutil.copy2(SCRIPT, scripts / 'outsourcerer.sh')
            shutil.copytree(SCRIPT.parent / 'lib', scripts / 'lib')
            for name in ('factory-tasks.sh', 'factory-land.sh', 'factory-flow.sh'):
                shutil.copy2(SCRIPT.parent / name, scripts / name)
            source = (SCRIPT.parent / 'lib/supervise.sh').read_text()
            changes = {
                '''trap 'if [ "$signalled" = 0 ]; then signalled=1; _sv_fail "killed by a signal" "$rearm"; fi; kill -TERM "$child" 2>/dev/null' TERM INT HUP''': '''trap 'kill -TERM "$child" 2>/dev/null' TERM INT HUP''',
                '''[ "$signalled" != 1 ] || return 2''': ':',
                '''10) _sv_fail "killed by a signal" "$rearm"; return 2 ;;''': '10) return 2 ;;',
                "trap 'exit 10' TERM INT HUP": '''trap '_sv_fail "killed by a signal" "$SCRIPT_PATH supervise"; exit 10' TERM INT HUP''',
            }
            for before, after in changes.items():
                self.assertEqual(source.count(before), 1)
                source = source.replace(before, after)
            (scripts / 'lib/supervise.sh').write_text(source)
            with mock.patch.dict(globals(), {'SCRIPT': scripts / 'outsourcerer.sh'}):
                result = unittest.TestResult()
                SuperviseSignal('test_signal_during_redirected_refresh_reports_once').run(result)
            self.assertTrue(result.failures or result.errors, 'old signal handler survived the regression test')

    def test_signal_during_redirected_refresh_reports_once(self):
        with tempfile.TemporaryDirectory(prefix='.signal-test-', dir=str(ROOT)) as d:
            p = Path(d); home = p / 'home'; state = p / "state with ' $x"; watch = p / 'watch'; bindir = p / 'bin'
            for x in (home, state, watch, bindir): x.mkdir()
            fifo = state / 'release.pipe'; os.mkfifo(fifo)
            release = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
            jq = shutil.which('jq'); self.assertIsNotNone(jq)
            shim = bindir / 'jq'
            shim.write_text('''#!/bin/bash
for f in "$OSRC_HOME"/supervise/orch/hub.json.tmp.*; do
  if [ -f "$f" ] && [ ! -e "$OSRC_HOME/tick-entered" ]; then
    : > "$OSRC_HOME/tick-entered"
    IFS= read -r _ < "$OSRC_HOME/release.pipe"
    break
  fi
done
exec "$REAL_JQ" "$@"
'''); shim.chmod(0o755)
            env = dict(os.environ, HOME=str(home), OSRC_HOME=str(state), CLAUDE_CODE_SESSION_ID='orch', OSRC_HEARTBEAT_DISABLED='1', REAL_JQ=jq, PATH=str(bindir) + os.pathsep + os.environ['PATH'])
            proc = subprocess.Popen(['/bin/bash', str(SCRIPT), 'supervise', '--session', 'orch', '--watch', str(watch)], cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 25
                while not (state / 'tick-entered').exists() and proc.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue((state / 'tick-entered').exists(), 'refresh did not start')
                proc.send_signal(signal.SIGTERM)
                ready, _, _ = select.select([proc.stdout], [], [], 5)
                prefix = os.read(proc.stdout.fileno(), 4096).decode(errors='replace') if ready else ''
                os.write(release, b'continue\n')
                rest, err = proc.communicate(timeout=20)
                out = prefix + rest
                self.assertIn('EVENT failed supervise ', prefix, 'signal event waited for the blocked refresh')
                self.assertEqual(proc.returncode, 2, out + err)
                self.assertEqual(out.count('EVENT failed supervise '), 1, out)
                self.assertIn('signal', out)
                self.assertIn('NEXT ', out)
                self.assertEqual(list((state / 'supervise/orch').glob('armed.*')), [], 'terminated waiter left an armed marker')
                self.assertNotIn('unbound variable', err)
            finally:
                os.close(release)
                if proc.poll() is None:
                    proc.kill(); proc.communicate()


if __name__ == '__main__':
    unittest.main(verbosity=2)
