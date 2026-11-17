// hub_alive_dom.js <path to hub-alive.js>: runs Mission Control's liveness strip and old-key page in node against a
// minimal DOM stub, a fake clock (window.OSRC_HUB_ALIVE_NOW) and a fake fetch. Prints PASS/FAIL lines.
// Driven by test_mc_alive.sh. No browser, no network.
'use strict';
const fs = require('fs'), vm = require('vm');
const code = fs.readFileSync(process.argv[2], 'utf8');
let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('PASS: ' + m); } else { fail++; console.log('FAIL: ' + m); } };

class El {
  constructor(tag) { this.tagName = tag; this.children = []; this.attrs = {}; this._text = ''; this.hidden = false; this.className = ''; this.listeners = {}; this.id = ''; }
  setAttribute(k, v) { this.attrs[k] = v; if (k === 'id') this.id = v; }
  append(...xs) { xs.forEach((x) => this.children.push(typeof x === 'string' ? new Text(x) : x)); }
  appendChild(x) { this.children.push(x); return x; }
  insertBefore(x) { this.children.unshift(x); return x; }
  get firstChild() { return this.children[0] || null; }
  set textContent(v) { this._text = String(v); this.children = []; }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
  set innerHTML(v) { this._text = String(v).replace(/<[^>]+>/g, ''); this.children = []; }
  all() { return [this].concat(...this.children.filter((c) => c instanceof El).map((c) => c.all())); }
  querySelector(sel) { return this.all().slice(1).find((e) => (sel[0] === '.' ? e.className.split(' ').includes(sel.slice(1)) : e.tagName === sel)) || null; }
  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); }
  click() { (this.listeners.click || []).forEach((f) => f()); }
}
class Text { constructor(t) { this.textContent = t; } }

function page(fetchImpl) {
  const body = new El('body'), head = new El('head');
  const welcome = new El('div'); welcome.setAttribute('id', 'welcome');
  const h1 = new El('h1'); h1.textContent = 'Loading your projects'; const p = new El('p'); p.textContent = 'Each orchestrator...';
  welcome.append(h1, p);
  const pe = new El('p'); pe.setAttribute('id', 'plist-empty'); pe.textContent = 'Loading your projects…';
  const main = new El('main'); main.setAttribute('id', 'main'); main.append(welcome);
  body.append(pe, main);
  const store = { 'osrc-hub-t': 'old0key0old0key0old0key0old0key0' };
  const sessionStorage = { getItem: (k) => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } };
  const clock = { t: 1800000000000 };
  const location = { href: 'http://127.0.0.1:8788/', origin: 'http://127.0.0.1:8788' };
  const document = { readyState: 'complete', head, body, createElement: (t) => new El(t), createTextNode: (t) => new Text(t),
    getElementById: (id) => body.all().find((e) => e.id === id) || null, addEventListener() {} };
  const window = { fetch: fetchImpl, OSRC_HUB_ALIVE_NOW: () => clock.t };
  vm.runInNewContext(code, { window, document, location, sessionStorage, URL, Map, Date, setInterval: () => 0, console });
  const bar = () => body.all().find((e) => e.id === 'osrc-alive');
  const text = () => (bar() ? bar().querySelector('.al-text').textContent : '');
  return { window, document, location, clock, bar, text, main, welcome: h1, plist: pe, paint: () => window.OSRC_HUB_ALIVE.paint() };
}
const res = (status, json) => ({ status, ok: status >= 200 && status < 300, clone() { return { json: () => Promise.resolve(json || {}) }; }, json: () => Promise.resolve(json || {}) });
const tick = () => new Promise((r) => setImmediate(r));

(async () => {
  // An old key: one 'Not live' line in the strip; the explanation and the Reopen button live in the main
  // pane only; Reopen POSTs this tab's old key and follows the URL the hub returns.
  for (const retired of [true, false]) {
    const calls = [];
    const P = page((url, opts) => { calls.push({ url, opts }); if (url === '/reopen') return Promise.resolve(retired ? res(200, { url: '/?t=newkey' }) : res(403, { error: 'unknown key', text: "This tab's key is not one this Mission Control issued. Run outsourcerer mc to open the current one." })); return Promise.resolve(res(403, { error: 'forbidden' })); });
    await P.window.fetch('/api/projects').catch(() => {}); await tick(); P.paint(); P.paint();
    if (retired) {
      ok(/^Not live \(HTTP 40[13]\)$/.test(P.text()), 'old key: the strip keeps one "Not live" line');
      ok(!P.bar().querySelector('button') && !P.bar().querySelector('.al-dead'), 'old key: no banner box or button in the strip');
      ok(P.plist.textContent === 'Loading your projects…', 'old key: the rail is not given a copy of the message');
      ok(P.welcome.textContent === 'This tab is from an older Mission Control', 'old key: the main pane says it (not a spinner)');
      ok(P.main.all().filter((e) => e.className === 'al-reopen').length === 1, 'old key: exactly one Reopen box, in the main pane, after repaints');
    }
    P.main.querySelector('.al-reopen').querySelector('button').click(); await tick(); await tick(); await tick();
    const rc = calls.find((c) => c.url === '/reopen');
    ok(rc && rc.opts.method === 'POST' && rc.opts.headers['X-Hub-Old-Token'] === 'old0key0old0key0old0key0old0key0', 'Reopen POSTs /reopen with this tab\'s old key' + (retired ? '' : ' (unknown key case)'));
    if (retired) ok(P.location.href === '/?t=newkey', 'a retired key: the tab moves to the URL the hub returned');
    else ok(P.location.href === 'http://127.0.0.1:8788/' && /Run outsourcerer mc/.test(P.main.querySelector('.al-note').textContent), 'an unknown key: the tab stays and shows the run-outsourcerer-mc text');
  }
  // H: live line, a failed call with the age of the last good data, a slow call past 10 s.
  {
    let mode = 'ok';
    const P = page(() => (mode === 'ok' ? Promise.resolve(res(200, { generated_at: 1800000000, projects: [] }))
      : mode === 'down' ? Promise.reject(new TypeError('Failed to fetch')) : new Promise(() => {})));
    await P.window.fetch('/api/projects'); await tick();
    P.clock.t += 7000; P.paint();
    ok(P.text() === 'Live · updated 7s ago', 'H: always-visible "Live · updated 7s ago" (got: ' + P.text() + ')');
    P.clock.t += 4 * 60000; mode = 'down';
    await P.window.fetch('/api/projects').catch(() => {}); await tick(); P.paint();
    ok(/^Not live: cannot reach Mission Control \(Failed to fetch\) · last good data 4 min ago$/.test(P.text()), 'H: a failed call shows the reason and the age of the last good data (got: ' + P.text() + ')');
    ok(/al-warn/.test(P.bar().className), 'H: the failure is styled as a warning');
    mode = 'ok'; await P.window.fetch('/api/projects'); await tick();
    mode = 'hang'; P.window.fetch('/api/answers'); P.clock.t += 11000; P.paint();
    ok(/^Waiting for Mission Control \(11s\) · last good data 11s ago$/.test(P.text()), 'H: a call past 10 s says it is still waiting, with the last good data age (got: ' + P.text() + ')');
  }
  // H: a page that never got a key says so instead of "Connecting" forever.
  {
    const P = page(() => new Promise(() => {}));
    P.paint();
    ok(/^Connecting to Mission Control/.test(P.text()), 'H: before the first call: connecting');
  }
  // D/E: needs-you rows ride in the export: an unreviewed READY lane with its age, a missing watcher.
  {
    const now = 1800000000;
    const P = page(() => Promise.resolve(res(200, { generated_at: now, projects: [{ id: 'S', name: 'TR build',
      watcher: { missingMin: 7, liveLanes: 3 }, alerts: [{ kind: 'unreviewed', lane: 'v185-x', since: now - 18 * 60, text: 'READY, no review started' },
        { kind: 'stalled', lane: 'S3', since: now - 11 * 60, text: 'still stalled 6m after one autonudge' }] }] })));
    await P.window.fetch('/api/projects'); await tick(); await tick(); P.paint();
    const t = P.bar().querySelector('ul').textContent;
    ok(/Needs you: No watcher for 7 min · TR build: 3 live lane\(s\), no supervise armed/.test(t), 'E: "No watcher for 7 min" is shown');
    ok(/Needs you: v185-x waits for review, 18 min/.test(t), 'D: a READY lane waiting for review shows as needs-you with its age');
    ok(/Needs you: S3 is stalled, 11 min · TR build: still stalled 6m after one autonudge/.test(t), 'B: an escalated stall shows as needs-you');
  }
  console.log('NODE: ' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})();
