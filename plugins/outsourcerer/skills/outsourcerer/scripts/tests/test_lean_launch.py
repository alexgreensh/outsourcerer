#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'lib/leanlaunch.sh'
SCRIPT = MODULE.parent.parent / 'outsourcerer.sh'
ROOT = Path(subprocess.check_output(['git', '-C', str(MODULE.parent), 'rev-parse', '--show-toplevel'], text=True).strip())
SH = '''. "$1"
have() { return 0; }
die() { echo "$*" >&2; exit 1; }
_cc_effort_flag() { :; }
MODEL_EXPLICIT=0; MODEL=''; EFFORT=''
_session_launch_cc
printf '%s\\n' "${SESSION_LAUNCH[@]}"
'''


class LeanLaunch(unittest.TestCase):
    def test_symlinked_cli_loads_lean_module(self):
        with tempfile.TemporaryDirectory(prefix='.lean-link-', dir=str(ROOT)) as d:
            p = Path(d); link = p / 'outsourcerer'; link.symlink_to(SCRIPT)
            cfg = p / 'invalid.json'; cfg.write_text('{}')
            env = dict(os.environ, HOME=d, OSRC_HOME=str(p / 'osrc'), OSRC_LEAN_LAUNCH='1', OSRC_LEAN_MCP_CONFIG=str(cfg), OUTSOURCERER_TMUX='osrc-test-L14-link')
            result = subprocess.run(['/bin/bash', str(link), '--provider', 'cc', 'session', 'start'], cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('lean launch: invalid MCP config', result.stdout + result.stderr)

    def run_launch(self, **extra):
        return subprocess.run(['/bin/bash', '-c', SH, 'bash', str(MODULE)], env=dict(os.environ, **extra), capture_output=True, text=True)

    def test_default_and_empty_strict_profile(self):
        default = self.run_launch()
        self.assertEqual(default.returncode, 0, default.stderr)
        self.assertNotIn('--strict-mcp-config', default.stdout.splitlines())
        lean = self.run_launch(OSRC_LEAN_LAUNCH='1')
        self.assertEqual(lean.returncode, 0, lean.stderr)
        args = lean.stdout.splitlines()
        self.assertIn('--strict-mcp-config', args)
        self.assertEqual(json.loads(args[args.index('--mcp-config') + 1]), {'mcpServers': {}})
        self.assertNotIn('--bare', args)

    def test_requested_server_config_must_exist_and_be_valid(self):
        with tempfile.TemporaryDirectory(prefix='.lean-test-', dir=str(ROOT)) as d:
            cfg = Path(d) / 'mcp.json'
            cfg.write_text('{"mcpServers":{"browser":{"command":"fake"}}}')
            run = self.run_launch(OSRC_LEAN_LAUNCH='1', OSRC_LEAN_MCP_CONFIG=str(cfg))
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn(str(cfg), run.stdout.splitlines())
            cfg.write_text('{}')
            invalid = self.run_launch(OSRC_LEAN_LAUNCH='1', OSRC_LEAN_MCP_CONFIG=str(cfg))
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn('invalid MCP config', invalid.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
