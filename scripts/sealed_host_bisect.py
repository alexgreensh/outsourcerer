#!/usr/bin/env python3
"""Replay original runners and change exactly one diff block per host case."""
import argparse
from contextlib import ExitStack
import difflib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RUNNER = Path('plugins/outsourcerer/skills/outsourcerer/scripts/sealed-run.sh')
BASE = '11598a4ac3a0c23159ae59dd931f5a6b56c9cbcc'
REGRESSION = '75302c2f23dd3c16262c626843265e61a58f1821'


def git_source(ref):
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    return subprocess.check_output(['git', '-C', str(ROOT), 'show', ref + ':' + str(RUNNER)], env=env, text=True)


def runner_cases(baseline, regression, current):
    old, new = baseline.splitlines(keepends=True), regression.splitlines(keepends=True)
    opcodes = difflib.SequenceMatcher(a=old, b=new, autojunk=False).get_opcodes()
    edits = [op for op in opcodes if op[0] != 'equal']

    def compose(active):
        pieces = []
        index = 0
        for tag, a, b, c, d in opcodes:
            if tag == 'equal':
                pieces.extend(old[a:b])
            else:
                pieces.extend(new[c:d] if index in active else old[a:b])
                index += 1
        return ''.join(pieces)

    all_edits = set(range(len(edits)))
    assert compose(set()) == baseline and compose(all_edits) == regression
    cases = [('baseline-original', baseline), ('regression-original', regression)]
    for i, (_, a, b, c, d) in enumerate(edits):
        label = 'hunk-%02d' % (i + 1)
        cases.append(('revert-' + label, compose(all_edits - {i})))
        cases.append(('apply-' + label, compose({i})))
    cases.append(('current-fixed', current))
    hunks = [dict(name='hunk-%02d' % (i + 1), old_start=a + 1, new_start=c + 1,
                  removed=''.join(old[a:b]), added=''.join(new[c:d]))
             for i, (_, a, b, c, d) in enumerate(edits)]
    return cases, hunks


def suite_body(root):
    return '''#!/bin/bash
set -eu
[ "$(pwd -P)" = "$TMPDIR" ]
exec 3<<'PROOF'
''' + 'x' * 70000 + '''
PROOF
/usr/bin/python3 -I -c 'import fcntl, os, pathlib
scratch = pathlib.Path(os.environ["TMPDIR"]).resolve()
assert pathlib.Path.cwd() == scratch
name = fcntl.fcntl(3, 50, bytes(1024)).split(bytes([0]))[0].decode()
assert pathlib.Path(name).resolve().is_relative_to(scratch), name
assert len(os.read(3, 80000)) == 70001
print("HEREDOC_SCRATCH_OK")'
cd ''' + shlex.quote(str(root)) + '''
[ "$(pwd -P)" = ''' + shlex.quote(str(root)) + ''' ]
git rev-parse --show-toplevel
/usr/bin/python3 -I -c 'import os; print("CHECKOUT_GETCWD=" + os.getcwd())'
echo SUITE_OK
'''


def diagnosis(rows):
    codes = {(row['variant'], row['input_tmpdir']): row['rc'] for row in rows}
    notes = []
    for location in ('normal', 'private-tmp'):
        if codes.get(('baseline-original', location)) != 0:
            notes.append(location + ': invalid control, baseline did not pass')
            continue
        if codes.get(('regression-original', location)) == 0:
            notes.append(location + ': regression did not reproduce')
            continue
        for row in rows:
            if row['input_tmpdir'] == location and row['variant'].startswith('revert-') and row['rc'] == 0:
                hunk = row['variant'][len('revert-'):]
                forward = codes.get(('apply-' + hunk, location))
                notes.append(location + ': reverting ' + hunk + ' repairs startup; applying it alone rc=' + str(forward))
    return notes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True, help='durable evidence parent outside system temp')
    parser.add_argument('--prepare-only', action='store_true', help='generate and syntax-check; never launch sandbox-exec')
    args = parser.parse_args()
    if sys.platform != 'darwin' and not args.prepare_only:
        parser.error('run this diagnostic on the macOS host')
    parent = args.out.resolve()
    hidden = (Path('/private/tmp'), Path('/private/var/tmp'), Path('/usr/tmp'))
    if any(parent == p or p in parent.parents for p in hidden):
        parser.error('--out must be a durable folder outside the hidden system temp directories')
    parent.mkdir(parents=True, exist_ok=True)
    proof = Path(tempfile.mkdtemp(prefix='sealed-bisect-', dir=parent))
    root = proof / 'checkout'
    tests = root / RUNNER.parent / 'tests'
    tests.mkdir(parents=True)
    git_env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    subprocess.run(['git', 'init', '-q', str(root)], env=git_env, check=True)
    suite = tests / 'probe.sh'
    suite.write_text(suite_body(root))
    baseline, regression = git_source(BASE), git_source(REGRESSION)
    versions, hunks = runner_cases(baseline, regression, (ROOT / RUNNER).read_text())
    (proof / 'hunks.json').write_text(json.dumps(hunks, indent=2) + '\n')
    spec = importlib.util.spec_from_file_location('matrix', ROOT / 'scripts/sealed_host_matrix.py')
    matrix = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(matrix)
    rows = []

    def interrupt(signum, frame):
        raise KeyboardInterrupt('host bisect interrupted')

    old_handlers = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        with ExitStack() as owned:
            if args.prepare_only:
                safe = proof / 'normal-runtime'
                private = proof / 'private-runtime-placeholder'
                safe.mkdir(); private.mkdir()
            else:
                safe = proof / 'normal-runtime'
                safe.mkdir()
                private = Path(owned.enter_context(tempfile.TemporaryDirectory(prefix='sealed-bisect-', dir='/private/tmp')))
            cases = [(name, source, location, base) for name, source in versions
                     for location, base in [('normal', safe), ('private-tmp', private)]]
            for name, source, location, base in cases:
                folder = proof / (name + '-' + location)
                folder.mkdir()
                runner = folder / 'runner.sh'
                runner.write_text(source)
                digest = hashlib.sha256(source.encode()).hexdigest()
                subprocess.run(['/bin/bash', '-n', str(runner)], check=True)
                if args.prepare_only:
                    rows.append(dict(variant=name, input_tmpdir=location, prepared=str(runner), sha256=digest, rc=None))
                else:
                    env = dict(git_env, HOME=str(proof / 'home'), OSRC_HOME=str(folder / 'state'),
                               TMPDIR=str(base), PYTHONDONTWRITEBYTECODE='1')
                    # run owns a process group and terminates it before scratch cleanup.
                    try:
                        rc = matrix.run(['/bin/bash', '-p', str(runner), str(suite.relative_to(root))],
                                        root, env, folder / 'output.log', 30)
                    finally:
                        # Only the baseline control can allocate inside this generated fixture.
                        for leftover in root.glob('.osrc-sealed.*'):
                            if leftover.is_dir() and not leftover.is_symlink():
                                shutil.rmtree(leftover)
                    body = (folder / 'output.log').read_text(errors='replace')
                    rows.append(dict(variant=name, input_tmpdir=location, rc=rc, sha256=digest,
                                     suite_ok='SUITE_OK' in body,
                                     here_doc_ok='HEREDOC_SCRATCH_OK' in body,
                                     getcwd_error='cannot access parent directories' in body,
                                     log=str(folder / 'output.log')))
                    print(name + '\t' + location + '\trc=' + str(rc), flush=True)
                (proof / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
    finally:
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
        print('PROOF_DIR=' + str(proof), flush=True)
    for note in diagnosis(rows) if not args.prepare_only else []:
        print('FINDING=' + note, flush=True)
    if not args.prepare_only:
        valid = all(any(row['variant'] == 'baseline-original' and row['input_tmpdir'] == location
                        and row['rc'] == 0 and row['suite_ok'] for row in rows)
                    for location in ('normal', 'private-tmp'))
        fixed = all(any(row['variant'] == 'current-fixed' and row['input_tmpdir'] == location
                        and row['rc'] == 0 and row['suite_ok'] for row in rows)
                    for location in ('normal', 'private-tmp'))
        print('CONTROL_VALID=' + str(valid), flush=True)
        print('CURRENT_FIXED=' + str(fixed), flush=True)
        return 0 if valid and fixed else 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
