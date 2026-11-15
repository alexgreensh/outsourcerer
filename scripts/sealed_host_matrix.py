#!/usr/bin/env python3
"""Run bounded pieces of the direct/sealed host matrix with durable row results."""
import argparse
from datetime import datetime
import json
import math
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
MODES = ('direct', 'sealed', 'python')


class MatrixInterrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def stop_owned(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run(command, directory, env, output, timeout):
    with output.open('w') as log:
        process = subprocess.Popen(['/usr/bin/nice', '-n', '19'] + command, cwd=directory,
                                   env=env, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop_owned(process)
            log.write('\nMATRIX_TIMEOUT: owned suite process group stopped\n')
            return 124
        except BaseException:
            stop_owned(process)
            raise


def matrix_markdown(rows):
    modes = [mode for mode in MODES if any(row['mode'] == mode for row in rows)]
    lines = ['| Suite | ' + ' | '.join(mode + ' rc' for mode in modes) + ' | Reason |',
             '|---|' + '---:|' * len(modes) + '---|']
    names = list(dict.fromkeys(row['suite'] for row in rows))
    for name in names:
        entries = {row['mode']: row for row in rows if row['suite'] == name}
        codes = [str(entries[mode]['rc']) if mode in entries and entries[mode]['rc'] is not None
                 else ('deferred' if mode in entries else '-') for mode in modes]
        reasons = list(dict.fromkeys(row['reason'] for row in entries.values() if row['reason']))
        detail = '; '.join(reasons).replace('|', '/').replace('\n', ' ')
        lines.append('| ' + name + ' | ' + ' | '.join(codes) + ' | ' + detail + ' |')
    return '\n'.join(lines) + '\n'


def persist_row(proof, rows, row):
    # Append and fsync first: an alarm cannot discard the already completed rows.
    with (proof / 'results.jsonl').open('a') as log:
        log.write(json.dumps(row) + '\n')
        log.flush()
        os.fsync(log.fileno())
    rows.append(row)
    for name, body in (('results.json', json.dumps(rows, indent=2) + '\n'),
                       ('matrix.md', matrix_markdown(rows))):
        pending = proof / (name + '.new')
        pending.write_text(body)
        pending.replace(proof / name)


def selected_tasks(args, parser):
    catalog = sorted(TESTS.glob('*.sh')) + [TESTS / (name + '.py') for name in PYTHON_SUITES]
    names = (args.suite or []) + [name for group in (args.suites or [])
                                 for item in group for name in item.split(',') if name]
    selected = []
    for name in names:
        matches = [path for path in catalog if name in (path.name, path.stem)]
        if len(matches) != 1:
            parser.error('unknown or ambiguous suite: ' + name)
        if matches[0] not in selected:
            selected.append(matches[0])
    modes = {'both': ('direct', 'sealed'), 'all': MODES}.get(args.mode, (args.mode,))
    tasks = [(path, mode) for path in (selected if names else catalog)
             for mode in modes if (path.suffix == '.py') == (mode == 'python')]
    if not tasks:
        parser.error('no suites match the selected mode')
    return tasks


def unexpected(row):
    if row['mode'] == 'sealed' and row['rc'] == 77 and 'unsupported suite: requires ' in row['reason']:
        return False
    return row['rc'] not in (None, 0) or row['failure_lines'] not in (None, 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', action='append', help='one filename/stem (legacy repeatable spelling)')
    parser.add_argument('--suites', nargs='+', action='append', help='filenames/stems, separated by spaces or commas')
    parser.add_argument('--mode', choices=('direct', 'sealed', 'both', 'python', 'all'), default='all',
                        help='run only selected modes; all also includes focused Python checks')
    parser.add_argument('--list', action='store_true', help='list selected mode/suite pairs without running')
    parser.add_argument('--include-slow', action='store_true', help='Linux integration only')
    parser.add_argument('--timeout', '--suite-timeout', type=float, default=120,
                        help='seconds per suite process group (default: 120); timeout rc is 124')
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error('--timeout must be a positive finite number')
    if args.include_slow and platform.system() == 'Darwin':
        parser.error('Mac load rule forbids conformance and test_factory_*; use Linux integration')
    tasks = selected_tasks(args, parser)
    if args.list:
        for path, mode in tasks:
            print(mode + '\t' + str(path.relative_to(ROOT)))
        return 0
    proof = ROOT / '.evidence-L14c' / ('host-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    bindir = proof / 'bin'
    bindir.mkdir(parents=True)
    for agent in AGENTS.split():
        stub = bindir / agent
        stub.write_text('#!/bin/sh\necho "MATRIX_DENIED: real ' + agent + '" >&2\nexit 99\n')
        stub.chmod(0o755)
    print('PROOF_DIR=' + str(proof), flush=True)
    (proof / 'head.txt').write_text(subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True))
    (proof / 'source.diff').write_text(subprocess.check_output(['git', '-C', str(ROOT), 'diff'], text=True))
    (proof / 'selection.json').write_text(json.dumps(dict(timeout=args.timeout,
        tasks=[dict(suite=path.name, mode=mode) for path, mode in tasks]), indent=2) + '\n')
    rows = []

    def record(path, mode):
        directory = proof / mode / path.name
        for name in ('home', 'state', 'tmp'):
            (directory / name).mkdir(parents=True)
        env = {'HOME': str(directory / 'home'), 'OSRC_HOME': str(directory / 'state'),
               'TMPDIR': str(directory / 'tmp') + '/', 'OSRC_HEARTBEAT_DISABLED': '1',
               'PYTHONDONTWRITEBYTECODE': '1',
               'PATH': str(bindir) + ':/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin'}
        if mode == 'sealed':
            command = ['/bin/bash', '-p', str(SCRIPTS / 'sealed-run.sh'), str(path.relative_to(ROOT))]
        else:
            command = ['/usr/bin/python3' if mode == 'python' else '/bin/bash', str(path)]
        output = directory / 'output.log'
        interrupted = None
        try:
            rc = run(command, ROOT, env, output, args.timeout)
        except MatrixInterrupted as error:
            interrupted = error
            rc = 128 + error.signum
        body = output.read_text(errors='replace')
        failures = len(re.findall(r'^\s*(?:FAIL(?:ED)?[: :]|not ok\b)', body, re.M))
        notes = sorted(set(re.findall(r'^.*(?:SKIP:|sandbox denies|unsupported suite:|denied capability:|MATRIX_DENIED:|MATRIX_TIMEOUT:|OS isolation unavailable|shell scratch unavailable).*$', body, re.M)))
        if interrupted:
            notes.append('interrupted by ' + signal.Signals(interrupted.signum).name)
        row = dict(suite=path.name, mode=mode, rc=rc, failure_lines=failures,
                   tmpdir=env['TMPDIR'], timeout=args.timeout, reason='; '.join(notes),
                   log=str(output.relative_to(proof)))
        persist_row(proof, rows, row)
        print(f'{path.name}\t{mode}\trc={rc}\tFAIL-lines={failures}\t' + row['reason'], flush=True)
        if interrupted:
            raise interrupted

    def interrupt(signum, frame):
        raise MatrixInterrupted(signum)

    previous = {}
    try:
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGALRM):
            previous[signum] = signal.signal(signum, interrupt)
        for path, mode in tasks:
            slow = path.name == 'conformance.sh' or path.name.startswith('test_factory_')
            if slow and not args.include_slow:
                persist_row(proof, rows, dict(suite=path.name, mode=mode, rc=None, failure_lines=None,
                    reason='DEFERRED: Mac load rule; Linux integration only', log=None))
                continue
            record(path, mode)
    except MatrixInterrupted as error:
        return 128 + error.signum
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
        print('MATRIX=' + str(proof / 'matrix.md'), flush=True)
    return int(any(unexpected(row) for row in rows))


if __name__ == '__main__':
    sys.exit(main())
