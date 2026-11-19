const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

test('opening, recurring and manual checks share progress and retry feedback', async () => {
  let tick, delay, requests = 0, finish;
  const ctx = { window: {}, setInterval(fn, ms) { tick = fn; delay = ms; } };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../lib/hub-assets/hub-plans.js'), 'utf8'), ctx);
  const button = {};
  ctx.window.OSRC_HUB_PLANS.startChecks(button, () => {
    requests++;
    return new Promise((resolve, reject) => { finish = { resolve, reject }; });
  });
  assert.equal(requests, 1);
  assert.equal(button.textContent, 'Checking…');
  await button.onclick();
  assert.equal(requests, 1);
  finish.resolve();
  await new Promise(setImmediate);
  assert.equal(button.textContent, 'Check again');
  assert.equal(delay, 300000);
  const recurring = tick();
  finish.reject(new Error('offline'));
  await recurring;
  assert.equal(button.textContent, 'Retry check');
  const manual = button.onclick();
  finish.resolve();
  await manual;
  assert.equal(requests, 3);
  assert.equal(button.disabled, false);
});

test('a pending poll cannot replace the limits from a completed plans check', async () => {
  const page = fs.readFileSync(path.join(__dirname, '../lib/hub.html'), 'utf8');
  const adapter = page.slice(page.indexOf('  function makeLocalDb()'), page.indexOf('  function subscribe(d)'));
  let check, release;
  const ctx = { window: { OSRC_HUB_PLANS: { startChecks(_, fn) { check = fn; } } },
    $() {}, setInterval() {}, renderLimits() {}, plansChecked: 0,
    api(url) { return url === '/api/projects' ? new Promise(r => { release = r; }) :
      Promise.resolve({ exported_at: 20, limits: [{ id: 'new' }] }); } };
  const db = vm.runInNewContext(adapter + '\nmakeLocalDb()', ctx);
  const seen = [];
  db.collection('limits').onSnapshot(s => seen.push(s.docs[0].id));
  await check();
  release({ limits: [{ id: 'old' }] });
  await new Promise(setImmediate);
  assert.deepEqual(seen, ['new']);
  assert.equal(ctx.plansChecked, 20000);
});
