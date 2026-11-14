#!/usr/bin/env python3
import os
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'lib/supervise.sh'
ROOT = Path(subprocess.check_output(['git', '-C', str(MODULE.parent), 'rev-parse', '--show-toplevel'], text=True).strip())


class SuperviseTick(unittest.TestCase):
    def test_supervise_publishes_snapshot(self):
        with tempfile.TemporaryDirectory(prefix='.tick-cli-', dir=str(ROOT)) as d:
            env = dict(os.environ, HOME=d, OSRC_HOME=str(Path(d) / 'osrc'), CLAUDE_CODE_SESSION_ID='orch')
            script = MODULE.parent.parent / 'outsourcerer.sh'
            run = subprocess.run(['/bin/bash', str(script), 'supervise', '--session', 'orch', '--once'], cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('EVENT done all', run.stdout)
            snapshot = json.loads((Path(d) / 'osrc/supervise/orch/hub.json').read_text())
            self.assertIsInstance(snapshot['projects'], list)
            self.assertIsInstance(snapshot['limits'], list)

    def test_snapshot_cadence_and_failed_refresh(self):
        with tempfile.TemporaryDirectory(prefix='.tick-test-', dir=str(ROOT)) as d:
            script = '''. "$1"
state_dir="$2"
cmd_hub_export() { cat "$state_dir/source"; [ ! -e "$state_dir/fail" ]; }
_sv_tick "$2" "$3"
'''
            def tick(now):
                return subprocess.run(['/bin/bash', '-c', script, 'bash', str(MODULE), d, str(now)], capture_output=True, text=True)
            p = Path(d)
            (p / 'source').write_text('{"projects":[1],"limits":[2]}')
            self.assertEqual(tick(100).returncode, 0)
            self.assertEqual((p / 'hub.json').read_text(), '{"projects":[1],"limits":[2]}')
            (p / 'source').write_text('{"projects":[3],"limits":[]}')
            self.assertEqual(tick(699).returncode, 0)
            self.assertIn('[1]', (p / 'hub.json').read_text())
            (p / 'fail').touch()
            self.assertNotEqual(tick(700).returncode, 0)
            self.assertIn('[1]', (p / 'hub.json').read_text())
            (p / 'fail').unlink()
            self.assertEqual(tick(700).returncode, 0)
            self.assertIn('[3]', (p / 'hub.json').read_text())
            (p / 'source').write_text('{invalid')
            self.assertNotEqual(tick(1300).returncode, 0)
            self.assertIn('[3]', (p / 'hub.json').read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
