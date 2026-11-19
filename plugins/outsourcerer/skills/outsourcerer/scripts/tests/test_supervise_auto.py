#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'lib/supervise.sh'
ROOT = Path(subprocess.check_output(['git', '-C', str(MODULE.parent), 'rev-parse', '--show-toplevel'], text=True).strip())
SH = r'''
. "$(dirname "$1")/atomic-claim.sh"
. "$1"
OSRC_HOME="$2"; export OSRC_HOME
_osrc_self() { printf osrc; }
_osrc_id_ok() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
_osrc_review_item_state() { printf '%s' "${STATE:-queued}"; }
cmd_review() { printf '%s\n' "$*" >> "$OSRC_HOME/calls"; [ "${FAIL:-0}" = 0 ]; }
_sv_auto_filter "$3" "$2"
'''


class AutoSupervision(unittest.TestCase):
    def test_only_ready_queue_transition_and_no_shell_execution(self):
        with tempfile.TemporaryDirectory(prefix='.auto-test-', dir=str(ROOT)) as d:
            p = Path(d); (p / 'remote').mkdir()
            (p / 'remote/lane.json').write_text(json.dumps({'head': 'abcdef0123456789'}))
            def row(kind='done', target='lane', detail='READY abcdef0 on branch', next='osrc review next', ts='1'):
                return '\t'.join(['5', ts, kind, target, detail, next])
            def run(line, **extra):
                return subprocess.run(['/bin/bash', '-c', SH, 'bash', str(MODULE), d, line], env=dict(os.environ, **extra), capture_output=True, text=True, check=True)
            valid = row()
            self.assertEqual(run(valid).stdout, '')
            self.assertEqual((p / 'calls').read_text(), 'next --exact lane abcdef0123456789\n')
            self.assertEqual(run(valid, STATE='inflight').stdout, '')
            self.assertEqual((p / 'calls').read_text(), 'next --exact lane abcdef0123456789\n')
            for bad in [row(kind='approval'), row(detail='VERDICT CHANGES'), row(detail='READY deadbee on branch'), row(target='../x'), row(next='osrc review next; touch ' + str(p / 'PWNED'))]:
                with self.subTest(row=bad):
                    self.assertEqual(run(bad).stdout.strip(), bad)
            self.assertFalse((p / 'PWNED').exists())
            failure = row(ts='2')
            self.assertEqual(run(failure, FAIL='1').stdout.strip(), failure)
            self.assertEqual(run(failure).stdout, '')

    def test_unknown_auto_kind_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='.auto-cli-', dir=str(ROOT)) as d:
            env = dict(os.environ, HOME=d, OSRC_HOME=str(Path(d) / 'osrc'), CLAUDE_CODE_SESSION_ID='orch')
            script = MODULE.parent.parent / 'outsourcerer.sh'
            result = subprocess.run(['/bin/bash', str(script), 'supervise', '--auto', 'approval', '--once'], cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('--auto cannot run approval', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
