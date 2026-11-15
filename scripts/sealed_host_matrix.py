#!/usr/bin/env python3
"""Run shell suites serially, directly and sealed, with durable host evidence."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'plugins/outsourcerer/skills/outsourcerer/scripts'
TESTS = SCRIPTS / 'tests'
AGENTS = 'tmux claude devin codex agy droid gemini cursor-agent hermes cline pi agent warp ollama opencode grok composer'
PYTHON_SUITES = ('test_sealed_runner', 'test_sandbox_final', 'test_lean_launch',
                 'test_review_packet', 'test_review_lifecycle', 'test_shell_scratch')


def run(command, directory, env, output, timeout):
    with output.open('w') as log:
        process = subprocess.Popen(['/usr/bin/nice', '-n', '19'] + command, cwd=directory,
                                   env=env, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            log.write('\nMATRIX_TIMEOUT: owned suite process group stopped\n')
            return 124


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', action='append', help='exact shell filename; default: every tests/*.sh')
    parser.add_argument('--list', action='store_true', help='list the matrix without running suites')
    parser.add_argument('--include-slow', action='store_true', help='Linux integration only')
    parser.add_argument('--timeout', type=int, default=660)
    args = parser.parse_args()
    if args.include_slow and platform.system() == 'Darwin':
        parser.error('Mac load rule forbids conformance and test_factory_*; use Linux integration')
    suites = sorted(TESTS.glob('*.sh'))
    if args.suite:
        by_name = {path.name: path for path in suites}
        unknown = sorted(set(args.suite) - by_name.keys())
        if unknown:
            parser.error('unknown suites: ' + ', '.join(unknown))
        suites = [by_name[name] for name in args.suite]
    if args.list:
        for suite in suites:
            print(suite.relative_to(ROOT))
        return 0
    proof = ROOT / '.evidence-L14c' / ('host-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    bindir = proof / 'bin'
    bindir.mkdir(parents=True)
    for agent in AGENTS.split():
        stub = bindir / agent
        stub.write_text('#!/bin/sh\necho "MATRIX_DENIED: real ' + agent + '" >&2\nexit 99\n')
        stub.chmod(0o755)
    print('PROOF_DIR=' + str(proof), flush=True)
    head = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True)
    (proof / 'head.txt').write_text(head)
    (proof / 'source.diff').write_text(subprocess.check_output(['git', '-C', str(ROOT), 'diff'], text=True))
    rows = []

    def record(suite, mode, command):
        directory = proof / mode / suite
        for name in ('home', 'state', 'tmp'):
            (directory / name).mkdir(parents=True)
        env = {'HOME': str(directory / 'home'), 'OSRC_HOME': str(directory / 'state'),
               'TMPDIR': str(directory / 'tmp') + '/', 'OSRC_HEARTBEAT_DISABLED': '1',
               'PYTHONDONTWRITEBYTECODE': '1',
               'PATH': str(bindir) + ':/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin'}
        output = directory / 'output.log'
        rc = run(command, ROOT, env, output, args.timeout)
        body = output.read_text(errors='replace')
        failures = len(re.findall(r'^\s*(?:FAIL(?:ED)?[: :]|not ok\b)', body, re.M))
        notes = sorted(set(re.findall(r'^.*(?:SKIP:|sandbox denies|unsupported suite:|denied capability:|MATRIX_DENIED:|OS isolation unavailable|shell scratch unavailable).*$', body, re.M)))
        row = dict(suite=suite, mode=mode, rc=rc, failure_lines=failures, tmpdir=env['TMPDIR'],
                   reason='; '.join(notes), log=str(output.relative_to(proof)))
        rows.append(row)
        (proof / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
        print(f'{suite}\t{mode}\trc={rc}\tFAIL-lines={failures}\t' + row['reason'], flush=True)

    for suite in suites:
        slow = suite.name == 'conformance.sh' or suite.name.startswith('test_factory_')
        if slow and not args.include_slow:
            for mode in ('direct', 'sealed'):
                rows.append(dict(suite=suite.name, mode=mode, rc=None, failure_lines=None,
                                 reason='DEFERRED: Mac load rule; Linux integration only', log=None))
            continue
        record(suite.name, 'direct', ['/bin/bash', str(suite)])
        record(suite.name, 'sealed', ['/bin/bash', '-p', str(SCRIPTS / 'sealed-run.sh'),
                                     str(suite.relative_to(ROOT))])
    # Host probes must print the real isolation branch, so CI is deliberately absent.
    for suite in PYTHON_SUITES:
        record(suite + '.py', 'python', ['/usr/bin/python3', str(TESTS / (suite + '.py'))])
    (proof / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
    table = ['| Suite | Direct rc | Sealed rc | Reason |', '|---|---:|---:|---|']
    for suite in suites:
        direct, sealed = [next(row for row in rows if row['suite'] == suite.name and row['mode'] == mode)
                          for mode in ('direct', 'sealed')]
        reason = sealed['reason'] or direct['reason']
        table.append(f"| {suite.name} | {direct['rc']} | {sealed['rc']} | {reason.replace('|', '/')} |")
    (proof / 'matrix.md').write_text('\n'.join(table) + '\n')
    print('MATRIX=' + str(proof / 'matrix.md'), flush=True)
    def unexpected(row):
        if row['mode'] == 'sealed' and row['rc'] == 77 and 'unsupported suite: requires ' in row['reason']:
            return False
        return row['rc'] not in (None, 0) or row['failure_lines'] not in (None, 0)
    return int(any(unexpected(row) for row in rows))


if __name__ == '__main__':
    sys.exit(main())
