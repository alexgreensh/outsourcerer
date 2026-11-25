#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

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
    def test_symlinked_cli_needs_no_installed_agents(self):
        with tempfile.TemporaryDirectory(prefix='.lean-path-', dir=str(ROOT)) as d:
            bindir = Path(d); (bindir / 'jq').symlink_to(shutil.which('jq'))
            # Reproduce CI: system tools and jq, without the outer harness's agent stubs.
            with mock.patch.dict(os.environ, {'PATH': d + ':/usr/bin:/bin'}):
                result = unittest.TestResult(); LeanLaunch('test_symlinked_cli_loads_lean_module').run(result)
            self.assertFalse(result.failures or result.errors, str(result.failures + result.errors))

    def test_symlinked_cli_loads_lean_module(self):
        with tempfile.TemporaryDirectory(prefix='.lean-link-', dir=str(ROOT)) as d:
            p = Path(d); link = p / 'outsourcerer'; link.symlink_to(SCRIPT)
            cfg = p / 'invalid.json'; cfg.write_text('{}')
            bindir = p / 'bin'; bindir.mkdir()
            for name in ('claude', 'tmux'):
                stub = bindir / name; stub.write_text('#!/bin/sh\nexit 99\n'); stub.chmod(0o755)
            env = dict(os.environ, HOME=d, OSRC_HOME=str(p / 'osrc'), OSRC_LEAN_LAUNCH='1', OSRC_LEAN_MCP_CONFIG=str(cfg), OUTSOURCERER_TMUX='osrc-test-L14b-link', PATH=str(bindir) + os.pathsep + os.environ['PATH'], OSRC_HEARTBEAT_DISABLED='1')
            result = subprocess.run(['/bin/bash', str(link), '--provider', 'cc', 'session', 'start'], cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('lean launch: invalid MCP config', result.stdout + result.stderr)

    def run_launch(self, **extra):
        return subprocess.run(['/bin/bash', '-c', SH, 'bash', str(MODULE)], env=dict(os.environ, **extra), capture_output=True, text=True)

    def test_default_launch_is_lean(self):
        # osrc-l5: a local lane must not start the user's whole MCP set unless asked.
        env = {k: v for k, v in os.environ.items() if k not in ('OSRC_LEAN_LAUNCH', 'OSRC_SESSION_MCP', 'OSRC_LEAN_MCP_CONFIG')}
        default = subprocess.run(['/bin/bash', '-c', SH, 'bash', str(MODULE)], env=env, capture_output=True, text=True)
        self.assertEqual(default.returncode, 0, default.stderr)
        args = default.stdout.splitlines()
        self.assertIn('--strict-mcp-config', args)
        self.assertEqual(json.loads(args[args.index('--mcp-config') + 1]), {'mcpServers': {}})
        full = self.run_launch(OSRC_SESSION_MCP='full')
        self.assertEqual(full.returncode, 0, full.stderr)
        self.assertNotIn('--strict-mcp-config', full.stdout.splitlines())
        forced = self.run_launch(OSRC_SESSION_MCP='full', OSRC_LEAN_LAUNCH='1')
        self.assertIn('--strict-mcp-config', forced.stdout.splitlines())
        bad = self.run_launch(OSRC_SESSION_MCP='everything')
        self.assertNotEqual(bad.returncode, 0)

    def test_declared_servers_only(self):
        with tempfile.TemporaryDirectory(prefix='.lean-decl-', dir=str(ROOT)) as d:
            home = Path(d)
            (home / '.claude.json').write_text(json.dumps({'mcpServers': {'browser': {'command': 'b'}, 'mail': {'command': 'm'}}}))
            sh = '''. "$1"; . "$2"
have() { return 0; }
die() { echo "$*" >&2; exit 1; }
_cc_effort_flag() { :; }
MODEL_EXPLICIT=0; MODEL=''; EFFORT=''; WITH_SPEC=' mcp=browser'; SESSION_NAME=decl
_session_launch_cc
printf '%s\\n' "${SESSION_LAUNCH[@]}"
'''
            run = subprocess.run(['/bin/bash', '-c', sh, 'bash', str(SCRIPT), str(MODULE)],
                                 env=dict(os.environ, HOME=d, OSRC_HOME=str(home / 'osrc'), OSRC_SOURCED='1', OSRC_HEARTBEAT_DISABLED='1'),
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            args = run.stdout.splitlines()
            cfg = json.loads(Path(args[args.index('--mcp-config') + 1]).read_text())
            self.assertEqual(sorted(cfg['mcpServers']), ['browser'])

    def test_empty_strict_profile(self):
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
