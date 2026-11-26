// hub_rv_dom.js <lib dir> <section>: page checks for the release review's second pass (F32, F33, F34, F48).
// Runs the page's own code (a slice of hub.html, the hub-assets files) in node against a minimal DOM stub
// and a fake clock. Prints PASS/FAIL lines. Driven by test_rv_hub.sh. No browser, no network.
'use strict';
const fs = require('fs'), vm = require('vm'), path = require('path');
const dir = process.argv[2], section = process.argv[3] || '';
let fail = 0;
const ok = (c, m) => { console.log((c ? 'PASS: ' : 'FAIL: ') + m); if (!c) fail++; };
const read = (f) => fs.readFileSync(path.join(dir, f), 'utf8');
const tick = () => new Promise((r) => setImmediate(r));

class El {
  constructor(tag, cls, text) { this.tagName = String(tag).toUpperCase(); this.className = cls || ''; this.children = []; this.dataset = {}; this.attrs = {}; this.id = ''; this._text = text == null ? '' : String(text); this.listeners = {}; this.style = {}; this.title = ''; this.type = ''; const s = this; this.classList = { add(c) { s.className += ' ' + c; }, remove() {}, toggle() {}, contains: (c) => s.className.split(' ').includes(c) }; }
  append(...xs) { xs.forEach((x) => this.children.push(typeof x === 'string' ? new El('#text', '', x) : x)); }
  appendChild(x) { this.children.push(x); return x; }
  insertBefore(x) { this.children.unshift(x); return x; }
  get firstChild() { return this.children[0] || null; }
  setAttribute(k, v) { this.attrs[k] = v; if (k === 'id') this.id = v; }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
  set textContent(v) { this._text = String(v); this.children = []; }
  all() { return [this].concat(...this.children.map((c) => c.all())); }
  querySelector(sel) { return this.all().slice(1).find((e) => (sel[0] === '.' ? e.className.split(' ').includes(sel.slice(1)) : e.tagName === sel.toUpperCase())) || null; }
  querySelectorAll() { return []; }
  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); }
}

// F32: a lane that turns `approval` while nothing else changes moves to "Waiting on you" on the next export.
function f32() {
  const page = read('hub.html');
  const slice = page.slice(page.indexOf('  const sig = (snap)'), page.indexOf('  function applyLimits'));
  const doc = { title: 'Mission Control', hidden: false, querySelector: () => null, addEventListener() {}, createElement: (t) => new El(t) };
  const sb = { window: {}, document: doc, setInterval: () => 0, console, Date, localStorage: { getItem: () => null, setItem() {} } };
  vm.createContext(sb);
  vm.runInContext(read('hub-assets/hub-attn.js'), sb);
  sb.A = sb.window.OSRC_HUB_ATTN({ el: (t, c, x) => new El(t, c, x), openDecs: () => [] });
  const api = vm.runInContext('let sigP = "", firstPull = true, pullErr = "", projects = [], current = null, renders = 0;'
    + 'function pickStart() { return null; } function renderRail() {} function pollRender() { renders++; }\n' + slice
    + '\n({ apply: applyProjects, get projects() { return projects; }, get renders() { return renders; } })', sb);
  const snap = (att, ex) => { const p = { id: 'p1', name: 'P', exported_at: ex, lanes: [{ id: 'l1', status: 'Building', attention: att }] }; return { docs: [{ id: 'p1', data: () => p }] }; };
  api.apply(snap('working', 1)); api.apply(snap('approval', 2));
  const before = api.renders;
  api.apply(snap('approval', 3));   // same data, one more export: only exported_at moved
  const p = api.projects[0];
  ok(sb.A.band(p, p.lanes[0]) === 'you', 'F32: the lane moves to "Waiting on you" on the export after it turned approval (band ' + sb.A.band(p, p.lanes[0]) + ')');
  ok(doc.title === '(1) Mission Control', 'F32: the tab title counts it (title "' + doc.title + '")');
  ok(api.renders > before, 'F32: the page re-renders so the band shows');
}

const S = { F32: f32 };
(async () => {
  if (!S[section]) { console.log('FAIL: unknown section ' + section); process.exit(1); }
  await S[section]();
  process.exit(fail ? 1 : 0);
})();
