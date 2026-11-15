#!/usr/bin/env python3
"""Run focused sandbox proofs on the host, outside an agent's outer sandbox."""
import argparse
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'plugins/outsourcerer/skills/outsourcerer/scripts'


def prove_here_documents(matrix, proof, env):
    with matrix.suite_scratch() as scratch:
        root = Path(scratch) / 'checkout'
        root.mkdir()
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        tests = root / 'plugins/outsourcerer/skills/outsourcerer/scripts/tests'
        tests.mkdir(parents=True)
        runner = tests.parent / 'sealed-run.sh'
        shutil.copy2(SCRIPTS / 'sealed-run.sh', runner)
        suite = tests / 'here-doc.sh'
        body = '''exec 3<<'PROOF'
''' + 'x' * 70000 + '''
PROOF
/usr/bin/python3 -I -c 'import fcntl, os, pathlib
name = fcntl.fcntl(3, 50, bytes(1024)).split(bytes([0]))[0].decode()
assert pathlib.Path(name).resolve().is_relative_to(pathlib.Path(os.environ["TMPDIR"]).resolve()), name
assert len(os.read(3, 80000)) == 70001
print("HEREDOC_SCRATCH")'
'''
        prefix = 'set -eu\ncd ' + shlex.quote(str(root)) + '\n[ -r ' + shlex.quote(str(suite)) + ' ]\n'
        for label, block in [('checkout-cwd-red', body),
                             ('scratch-subshell-green', '(cd "$TMPDIR" || exit 1\n' + body + ')\n')]:
            suite.write_text(prefix + block)
            result = subprocess.run(['/bin/bash', '-p', str(runner), str(suite.relative_to(root))],
                                    cwd=root, env=dict(env, TMPDIR=scratch), capture_output=True, text=True)
            (proof / (label + '.log')).write_text(result.stdout + result.stderr)
            if label.endswith('red'):
                assert result.returncode == 1 and 'here document' in result.stderr, result.stderr
            else:
                assert result.returncode == 0 and 'HEREDOC_SCRATCH' in result.stdout, result.stderr
        print('checkout here-document red/green: pass', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True, help='durable evidence parent')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    proof = Path(tempfile.mkdtemp(prefix='sealed-host-probe-', dir=args.out.resolve()))
    scratch = proof / 'tmp'
    scratch.mkdir()
    env = dict(os.environ, OSRC_HOME=str(proof / 'state'), TMPDIR=str(scratch),
               PYTHONDONTWRITEBYTECODE='1')
    if sys.platform == 'linux':
        env['CI'] = 'true'
    else:
        env.pop('CI', None)
    failures = []
    for suite in ('test_sealed_fixes.py', 'test_sealed_runner.py'):
        with (proof / (suite + '.log')).open('w') as log:
            rc = subprocess.call(['/usr/bin/nice', '-n', '19', sys.executable,
                                  str(SCRIPTS / 'tests' / suite)], env=env, cwd=ROOT,
                                 stdout=log, stderr=subprocess.STDOUT)
        print(suite + ': rc=' + str(rc), flush=True)
        if rc:
            failures.append(suite)
    spec = importlib.util.spec_from_file_location('matrix', ROOT / 'scripts/sealed_host_matrix.py')
    matrix = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(matrix)
    if sys.platform == 'darwin':
        try:
            prove_here_documents(matrix, proof, env)
        except (AssertionError, subprocess.SubprocessError) as error:
            failures.append('checkout-here-documents')
            print('checkout here-document red/green: FAIL ' + str(error), flush=True)
    with tempfile.TemporaryDirectory(prefix='agent-guard-', dir=scratch) as temp:
        folder = Path(temp)
        agent = folder / 'claude'
        agent.write_text('#!/bin/sh\necho REAL-AGENT-RAN\n')
        agent.chmod(0o755)
        assert subprocess.check_output([str(agent)], text=True).strip() == 'REAL-AGENT-RAN'
        try:
            command = matrix.direct_command([str(agent)], folder, agent_paths=[agent])
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            (proof / 'absolute-agent.log').write_text(result.stdout + result.stderr)
            # Reject a guard that simply cannot start: a benign command must work.
            benign = subprocess.run(matrix.direct_command(['/usr/bin/true'], folder, agent_paths=[agent]),
                                    env=env, capture_output=True, text=True)
            assert benign.returncode == 0, benign.stderr
            assert result.returncode != 0 and 'REAL-AGENT-RAN' not in result.stdout
            print('absolute agent guard: pass', flush=True)
        except (RuntimeError, AssertionError) as error:
            failures.append('absolute-agent-guard')
            print('absolute agent guard: FAIL ' + str(error), flush=True)
    print('PROOF_DIR=' + str(proof), flush=True)
    return int(bool(failures))


if __name__ == '__main__':
    sys.exit(main())
