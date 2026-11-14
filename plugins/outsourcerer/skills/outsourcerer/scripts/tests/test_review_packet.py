#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'lib/review.sh'
ROOT = Path(subprocess.check_output(['git', '-C', str(MODULE.parent), 'rev-parse', '--show-toplevel'], text=True).strip())
SH = '''. "$1"
OSRC_HOME="$2"; export OSRC_HOME
_osrc_id_ok() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
_osrc_review_write_brief "$3" "${4:-}"
'''


class ReviewPacket(unittest.TestCase):
    def test_rereview_and_final_diff_with_findings_and_latest_round(self):
        with tempfile.TemporaryDirectory(prefix='.packet-test-', dir=str(ROOT)) as d:
            p = Path(d); (p / 'review/items').mkdir(parents=True); (p / 'briefs').mkdir(); (p / 'out').mkdir()
            brief = p / 'briefs/L1.md'; brief.write_text('Build the feature.\n')
            (p / 'out/L1-REPORT.md').write_text('## Round 1\nold text\n## Round 2\nnew evidence\n## Other\nexclude this\n')
            oldsha, newsha = 'a' * 40, 'b' * 40
            oldid, newid = 'L1-aaaaaaa', 'L1-bbbbbbb'
            findings = p / ('review/' + oldid + '.VERDICT')
            findings.write_text('CHANGES\nFix the race\nAdd a test\n')
            prior = {'id': oldid, 'lane': 'L1', 'state': 'verdict', 'head': oldsha, 'sha_reviewed': oldsha, 'verdict_ts': 42, 'findings': str(findings)}
            current = {'id': newid, 'lane': 'L1', 'state': 'queued', 'head': newsha, 'branch': 'feature', 'url': 'example/repo', 'transport': 'gh', 'base': 'main', 'brief': str(brief)}
            (p / ('review/items/' + oldid + '.json')).write_text(json.dumps(prior))
            (p / ('review/items/' + newid + '.json')).write_text(json.dumps(current))
            def build(final=''):
                result = subprocess.run(['/bin/bash', '-c', SH, 'bash', str(MODULE), d, newid, final], capture_output=True, text=True, check=True)
                return Path(result.stdout).read_text()
            packet = build()
            self.assertIn('git diff ' + oldsha + ' FETCH_HEAD', packet)
            self.assertIn('- [ ] Fix the race', packet)
            self.assertIn('- [ ] Add a test', packet)
            self.assertIn('new evidence', packet)
            self.assertNotIn('old text', packet)
            self.assertNotIn('exclude this', packet)
            final = build('final')
            self.assertIn('git diff origin/main...FETCH_HEAD', final)
            self.assertNotIn('git diff ' + oldsha + ' FETCH_HEAD', final)
            self.assertIn('- [ ] Fix the race', final)
            prior['findings'] = str(p / 'secret')
            (p / 'secret').write_text('not for the packet')
            (p / ('review/items/' + oldid + '.json')).write_text(json.dumps(prior))
            fallback = build()
            self.assertIn('git diff origin/main...FETCH_HEAD', fallback)
            self.assertNotIn('not for the packet', fallback)


if __name__ == '__main__':
    unittest.main(verbosity=2)
