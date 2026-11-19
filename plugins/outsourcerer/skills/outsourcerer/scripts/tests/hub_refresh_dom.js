// Exercise the page's local adapter with a stale poll still in flight.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const page = fs.readFileSync(require('node:path').join(__dirname, '../lib/hub.html'), 'utf8');
const adapter = page.slice(page.indexOf('  function makeLocalDb()'), page.indexOf('  function subscribe(d)'));
async function main() {
  let release, posts = 0;
  const state = { window: {}, sigP: 'previous render', alsoSig: '[]', setInterval() {}, clearInterval() {},
    api(path, opts) {
      if (path === '/api/projects') return new Promise(resolve => { release = resolve; });
      assert.equal(path, '/api/refresh');
      assert.equal(opts.method, 'POST');
      posts++;
      return Promise.resolve({ projects: [{ id: 'fresh' }] });
    } };
  const db = vm.runInNewContext(adapter + '\nmakeLocalDb()', state);
  const seen = [];
  db.collection('projects').onSnapshot(s => seen.push(s.docs[0].id));
  await db.doc('refresh/project--demo').set();
  release({ projects: [{ id: 'old' }] });
  await new Promise(setImmediate);
  assert.equal(posts, 1);
  assert.deepEqual(seen, ['fresh']);
  assert.equal(state.sigP, '');
  console.log('hub refresh DOM: 1 passed, 0 failed');
}
main().catch(e => { console.error(e); process.exitCode = 1; });
