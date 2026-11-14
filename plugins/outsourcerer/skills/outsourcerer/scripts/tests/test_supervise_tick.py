#!/usr/bin/env python3
import os
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

MODULE = Path(__file__).resolve().parents[1] / 'lib/supervise.sh'
ROOT = Path(subprocess.check_output(['git', '-C', str(MODULE.parent), 'rev-parse', '--show-toplevel'], text=True).strip())


class SuperviseTick(unittest.TestCase):
    def test_cadence_and_refresh_guards_detect_mutations(self):
        source = MODULE.read_text()
        old_check = '''if ! cmd_hub_export > "$tmp" || ! jq -e '(.projects | type) == "array" and (.limits | type) == "array"' "$tmp" >/dev/null 2>&1; then'''
        mutations = {
            'producer failure': (old_check, '''cmd_hub_export > "$tmp"; if ! jq -e '(.projects | type) == "array" and (.limits | type) == "array"' "$tmp" >/dev/null 2>&1; then'''),
            'bad json': (old_check, '''if ! cmd_hub_export > "$tmp"; then'''),
            'cadence': ('''[ "$last" -eq 0 ] || [ $((now - last)) -ge "$interval" ] || return 0''', ':'),
        }
        for name, (old, new) in mutations.items():
            with self.subTest(guard=name), tempfile.TemporaryDirectory(prefix='.tick-mutant-', dir=str(ROOT)) as d:
                self.assertEqual(source.count(old), 1)
                module = Path(d) / 'supervise-mutant.sh'; module.write_text(source.replace(old, new))
                with mock.patch.dict(globals(), {'MODULE': module}):
                    result = unittest.TestResult()
                    SuperviseTick('test_snapshot_cadence_and_failed_refresh').run(result)
                self.assertTrue(result.failures or result.errors, name + ' mutant survived')

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
