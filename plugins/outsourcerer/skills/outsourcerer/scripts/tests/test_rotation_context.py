#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'outsourcerer.sh'
ROOT = Path(subprocess.check_output(['git', '-C', str(SCRIPT.parent), 'rev-parse', '--show-toplevel'], text=True).strip())


class ContextRotation(unittest.TestCase):
    def test_threshold_cache_tokens_and_missing_usage(self):
        with tempfile.TemporaryDirectory(prefix='.rotation-test-', dir=str(ROOT)) as tmp:
            base = Path(tmp)
            projects = base / 'projects'
            slug = re.sub(r'[^A-Za-z0-9]', '-', str(ROOT))
            transcript = projects / slug / 'orch.jsonl'
            transcript.parent.mkdir(parents=True)
            env = dict(os.environ, HOME=str(base), OSRC_HOME=str(base / 'osrc'), OSRC_CLAUDE_PROJECTS_DIR=str(projects), CLAUDE_CODE_SESSION_ID='orch')
            def run(**extra):
                return subprocess.run(['/bin/bash', str(SCRIPT), 'handover', '--check-context'], cwd=ROOT, env=dict(env, **extra), capture_output=True, text=True)
            missing = run()
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn('context usage unavailable', missing.stderr)
            def write(input_tokens, read, create):
                transcript.write_text(json.dumps({'message': {'role': 'assistant', 'usage': {'input_tokens': input_tokens, 'cache_read_input_tokens': read, 'cache_creation_input_tokens': create}}}) + '\n')
            write(10000, 120000, 19999)
            below = run()
            self.assertEqual(below.returncode, 0, below.stderr)
            self.assertIn('rotation not due', below.stdout)
            write(10000, 120000, 20000)
            due = run()
            self.assertEqual(due.returncode, 0, due.stderr)
            self.assertIn('rotation due', due.stdout)
            handovers = list((base / 'osrc/handover').glob('*.md'))
            self.assertEqual(len(handovers), 1)
            self.assertIn('adopt orch', handovers[0].read_text())
            self.assertIn('rotation not due', run(OSRC_ORCH_CTX_MAX='200000').stdout)
            self.assertNotEqual(run(OSRC_ORCH_CTX_MAX='bad').returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
