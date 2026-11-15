#!/usr/bin/env python3
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = Path(subprocess.check_output(['git', '-C', str(SCRIPTS), 'rev-parse', '--show-toplevel'], text=True).strip())
SH = r'''
. "$1/lib/screen.sh"
. "${APPROVER:-$1/lib/approver.sh}"
OSRC_HOME="$2"; export OSRC_HOME
_osrc_screen_engine_of() { printf cc; }
_osrc_screen_capture() { if [ -f "$OSRC_HOME/pressed" ]; then cat "$SCRIPTS/tests/fixtures/screen/cc-idle-after-work.ansi"; else cat "$SCRIPTS/tests/fixtures/screen/cc-permission-bash.ansi"; fi; }
_osrc_approver_root() { printf '%s' "$OSRC_HOME/worktree"; }
_osrc_approver_classify() { printf 'approve test'; }
_osrc_approver_log() { [ "$FAIL_LOG" != 1 ] || return 1; printf '%s\n' "$4" >> "$OSRC_HOME/log"; }
tmux() { [ "$1" = send-keys ] || return 1; : > "$OSRC_HOME/pressed"; }
mkdir -p "$OSRC_HOME/worktree" "$OSRC_HOME/approver/policy"
printf 'safe\n' > "$OSRC_HOME/approver/policy/sess"
osrc_approver_tick sess sess
'''


class ApprovalAudit(unittest.TestCase):
    def test_missing_log_guard_mutation_is_detected(self):
        with tempfile.TemporaryDirectory(prefix='.audit-mutant-', dir=str(ROOT)) as d:
            source = (SCRIPTS / 'lib/approver.sh').read_text()
            mutated, count = re.subn(r'if ! _osrc_approver_log ([^\n]+) attempt ([^\n]+); then', 'if false; then', source, count=1)
            self.assertEqual(count, 1)
            module = Path(d) / 'approver-mutant.sh'; module.write_text(mutated)
            state = Path(d) / 'state'; state.mkdir()
            env = dict(os.environ, SCRIPTS=str(SCRIPTS), APPROVER=str(module), FAIL_LOG='1', OSRC_APPROVER_VERIFY_POLLS='1')
            result = subprocess.run(['/bin/bash', '-c', SH, 'bash', str(SCRIPTS), str(state)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((state / 'pressed').exists(), 'mutant should violate the no-press guard')

    def test_log_failure_holds_without_sending(self):
        with tempfile.TemporaryDirectory(prefix='.audit-test-', dir=str(ROOT)) as d:
            env = dict(os.environ, SCRIPTS=str(SCRIPTS), FAIL_LOG='1', OSRC_APPROVER_VERIFY_POLLS='1')
            result = subprocess.run(['/bin/bash', '-c', SH, 'bash', str(SCRIPTS), d], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn('approval log is not writable', result.stdout)
            self.assertFalse((Path(d) / 'pressed').exists())

    def test_attempt_precedes_approved_decision(self):
        with tempfile.TemporaryDirectory(prefix='.audit-test-', dir=str(ROOT)) as d:
            env = dict(os.environ, SCRIPTS=str(SCRIPTS), FAIL_LOG='0', OSRC_APPROVER_VERIFY_POLLS='1')
            result = subprocess.run(['/bin/bash', '-c', SH, 'bash', str(SCRIPTS), d], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((Path(d) / 'log').read_text().splitlines(), ['attempt', 'approve'])
            self.assertTrue((Path(d) / 'pressed').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
