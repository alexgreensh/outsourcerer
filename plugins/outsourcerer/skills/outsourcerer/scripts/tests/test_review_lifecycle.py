#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

MODULE = Path(__file__).resolve().parents[1] / 'lib/review.sh'
ROOT = Path(subprocess.check_output(['git', '-C', str(MODULE.parent), 'rev-parse', '--show-toplevel'], text=True).strip())
SH = r'''
. "$1"
OSRC_HOME="$2"; SCRIPT_PATH="$2/stop"; export OSRC_HOME
_osrc_review_screen() { printf '%s' "$SCREEN"; }
_managed_endpoint_live() { [ "$MANAGED" = yes ]; }
_osrc_lock() { mkdir "$1" 2>/dev/null; }
_osrc_unlock() { rmdir "$1"; }
_osrc_jq_set() { jq "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
tmux() { return 1; }
_osrc_review_ctx_pct() { printf '%s' "$CTX"; }
case "$3" in
  idle) _osrc_review_idle_retire "${SESS:-rv}" "$4" "$SCREEN" "$QUEUED" "$INFLIGHT" ;;
  rotation) _osrc_review_rotation_due rv ;;
esac
'''


class ReviewLifecycle(unittest.TestCase):
    def test_retirement_guards_detect_mutations(self):
        source = MODULE.read_text()
        mutations = {
            'idle duration': ('[ $((now - since)) -ge $((mins * 60)) ] || return 0', ':'),
            'managed session': ('|| ! _managed_endpoint_live "$s" "$s"', ''),
            'idle state': ('if [ "$scr" != idle ] || [ "$queued" -ne 0 ]', 'if [ "$queued" -ne 0 ]'),
            'queue state': ('[ "$queued" -ne 0 ] || ', ''),
        }
        for name, (old, new) in mutations.items():
            with self.subTest(guard=name), tempfile.TemporaryDirectory(prefix='.review-mutant-', dir=str(ROOT)) as d:
                self.assertEqual(source.count(old), 1)
                module = Path(d) / 'review-mutant.sh'; module.write_text(source.replace(old, new))
                with mock.patch.dict(globals(), {'MODULE': module}):
                    result = unittest.TestResult()
                    ReviewLifecycle('test_retirement_requires_idle_empty_and_managed').run(result)
                self.assertTrue(result.failures or result.errors, name + ' mutant survived')

    def test_rotation_defaults_and_overrides(self):
        with tempfile.TemporaryDirectory(prefix='.review-test-', dir=str(ROOT)) as d:
            p = Path(d); (p / 'review').mkdir()
            state = p / 'review/reviewer.json'
            def check(reviews, ctx, **extra):
                state.write_text(json.dumps({'session': 'rv', 'reviews': reviews}))
                env = dict(os.environ, CTX=str(ctx), **extra)
                return subprocess.run(['/bin/bash', '-c', SH, 'bash', str(MODULE), d, 'rotation'], env=env, capture_output=True, text=True)
            self.assertNotEqual(check(1, 35).returncode, 0)
            self.assertEqual(check(2, 0).returncode, 0)
            self.assertEqual(check(0, 36).returncode, 0)
            self.assertNotEqual(check(2, 36, OSRC_REVIEW_ROTATE_K='3', OSRC_REVIEW_CTX_MAX='40').returncode, 0)

    def test_retirement_requires_idle_empty_and_managed(self):
        with tempfile.TemporaryDirectory(prefix='.review-test-', dir=str(ROOT)) as d:
            p = Path(d); (p / 'review/items').mkdir(parents=True)
            state = p / 'review/reviewer.json'
            state.write_text('{"session":"rv","reviews":0}')
            stop = p / 'stop'; stop.write_text('#!/bin/sh\nprintf called >> "$OSRC_HOME/stopped"\n'); stop.chmod(0o755)
            def tick(now, screen='idle', queued='0', inflight='', managed='yes'):
                env = dict(os.environ, SCREEN=screen, QUEUED=queued, INFLIGHT=inflight, MANAGED=managed)
                return subprocess.run(['/bin/bash', '-c', SH, 'bash', str(MODULE), d, 'idle', str(now)], env=env, capture_output=True, text=True)
            self.assertEqual(tick(100).returncode, 0)
            self.assertEqual(tick(3099).returncode, 0)
            self.assertFalse((p / 'stopped').exists())
            self.assertEqual(tick(3100, managed='no').returncode, 0)
            self.assertFalse((p / 'stopped').exists())
            self.assertEqual(tick(3100, queued='1').returncode, 0)
            self.assertEqual(tick(3200).returncode, 0)
            self.assertEqual(tick(6200, inflight='review-in-progress').returncode, 0)
            self.assertFalse((p / 'stopped').exists())
            self.assertEqual(tick(6200).returncode, 0)
            self.assertEqual(tick(9200, screen='working').returncode, 0)
            self.assertEqual(tick(9300).returncode, 0)
            self.assertFalse((p / 'stopped').exists())
            self.assertEqual(tick(12300).returncode, 0)
            self.assertEqual((p / 'stopped').read_text(), 'called')
            self.assertEqual(json.loads(state.read_text())['session'], '')


if __name__ == '__main__':
    unittest.main(verbosity=2)
