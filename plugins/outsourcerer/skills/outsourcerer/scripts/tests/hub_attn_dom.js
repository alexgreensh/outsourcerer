// hub_attn_dom.js <lib/hub-assets dir>: runs hub-attn.js (bands, title, favicon, notification, keys) and the
// decision-card ids of hub-decide.js in node against a minimal DOM stub and a fake clock. Prints PASS/FAIL
// lines. Driven by test_hub_attn.sh. No browser, no network.
'use strict';
const fs = require('fs'), vm = require('vm'), path = require('path');
const dir = process.argv[2];
let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('PASS: ' + m); } else { fail++; console.log('FAIL: ' + m); } };

class El {
  constructor(tag, cls, text) { this.tagName = String(tag).toUpperCase(); this.className = cls || ''; this.children = []; this.dataset = {}; this.attrs = {}; this.id = ''; this._text = text == null ? '' : String(text); this.listeners = {}; this.parent = null; this.rect = { left: 0, top: 100, width: 300, bottom: 200 }; this.disabled = false; this.style = {}; const self = this; this.classList = { add(c) { self.className += ' ' + c; }, remove() {}, toggle() {} }; }
  append(...xs) { xs.forEach((x) => { const n = typeof x === 'string' ? new El('#text', '', x) : x; n.parent = this; this.children.push(n); }); }
  appendChild(x) { this.append(x); return x; }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); this.parent = null; }
  setAttribute(k, v) { this.attrs[k] = v; }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
  set textContent(v) { this._text = String(v); this.children = []; }
  all() { return [this].concat(...this.children.map((c) => c.all())); }
  matches(sel) { return sel === '[data-wait]' ? this.dataset.wait != null : sel[0] === '.' ? this.className.split(' ').includes(sel.slice(1)) : this.tagName === sel.toUpperCase(); }
  querySelectorAll(sel) { return this.all().slice(1).filter((e) => e.matches(sel)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  closest(sel) { for (let e = this; e; e = e.parent) if (e.matches(sel)) return e; return null; }
  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); }
  click() { (this.listeners.click || []).forEach((f) => f({ stopPropagation() {} })); }
  focus() { doc.activeElement = this; }
  scrollIntoView() {}
  getBoundingClientRect() { return this.rect; }
}
const body = new El('body'), icon = new El('link'); icon.href = 'data:image/svg+xml,orig';
const doc = { title: 'Outsourcerer Mission Control', hidden: false, body, activeElement: null, listeners: {},
  createElement: (t) => (t === 'canvas' ? { width: 0, height: 0, getContext: () => ({ fillText() {}, beginPath() {}, arc() {}, fill() {}, stroke() {} }), toDataURL: () => 'data:image/png;base64,DOT' } : new El(t)),
  createTextNode: (t) => new El('#text', '', t),
  querySelector: (s) => (s === 'link[rel="icon"]' ? icon : body.querySelector(s)), querySelectorAll: (s) => body.querySelectorAll(s),
  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); } };
const notes = [], store = {};
let clock = 1800000000000;
class FakeDate extends Date { static now() { return clock; } }
const Notification = function (t, o) { notes.push({ t, o }); }; Notification.permission = 'granted'; Notification.requestPermission = () => Promise.resolve('granted');
const win = { innerHeight: 800 };
const sb = { window: win, document: doc, Date: FakeDate, Notification, setInterval: () => 0, Promise, console,
  localStorage: { getItem: (k) => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } } };
win.Notification = Notification; win.localStorage = sb.localStorage;
vm.createContext(sb);
vm.runInContext(fs.readFileSync(path.join(dir, 'hub-attn.js'), 'utf8'), sb);
vm.runInContext(fs.readFileSync(path.join(dir, 'hub-decide.js'), 'utf8'), sb);
const el = (t, c, x) => new El(t, c, x);
const key = (k, target) => { const e = { key: k, target: target || body, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } }; doc.listeners.keydown.forEach((f) => f(e)); return e; };

// ---- tracker: bands move only after one more export ----
const T = win.OSRC_HUB_ATTN.internals.Tracker(), none = () => [];
const P = (gen, att, decs) => [{ id: 'p1', name: 'Garden app', exported_at: gen, lanes: [{ id: 'a', short: 'Port the scheduler', note: 'SECRET lane output', attention: att }], decisions: decs || [] }];
let r = T.update(P(1, 'working'), none);
ok(r.count === 0 && r.fresh.length === 0 && T.band(P(1)[0], { id: 'a' }) === 'work', 'first export: a working lane is in the working band, nothing waits');
r = T.update(P(2, 'approval'), none);
ok(r.count === 0 && T.band(P(2)[0], { id: 'a' }) === 'work', 'a lane that just turned to approval keeps its band for one export');
r = T.update(P(2, 'approval'), none);
ok(T.band(P(2)[0], { id: 'a' }) === 'work', 'the same export seen again does not count as a second cycle');
r = T.update(P(3, 'approval'), none);
ok(r.count === 1 && T.band(P(3)[0], { id: 'a' }) === 'you' && r.fresh.length === 1 && r.fresh[0].name === 'Garden app', 'held for one more export: it moves to waiting on you and counts as new');
T.update(P(4, 'ready'), none); r = T.update(P(5, 'approval'), none);
ok(T.band(P(5)[0], { id: 'a' }) === 'you' && r.fresh.length === 0, 'a one-export flicker never moves the lane or re-notifies');
const T2 = win.OSRC_HUB_ATTN.internals.Tracker();
r = T2.update(P(1, 'approval', [{ id: 'D1', owner: 's1' }]), (p) => p.decisions);
ok(r.count === 2 && r.fresh.length === 0, 'first load: a held approval and an open question count 2, none is "new"');

// ---- notification text ----
const nt = win.OSRC_HUB_ATTN.internals.noteText([{ name: 'A' }, { name: 'B' }, { name: 'C' }, { name: 'D' }]);
ok(nt === 'A, B, C and 1 more: something is waiting on you', 'one grouped notification: project names plus a fixed headline (' + nt + ')');

// ---- steady: on screen and unmoved about one second ----
let t = 0; const S = win.OSRC_HUB_ATTN.internals.Steady(() => t), R = { left: 0, top: 100, width: 10, bottom: 120 };
ok(!S('k', R, 800), 'a card seen for the first time does not take keys');
t = 900; ok(!S('k', R, 800), 'not yet after 0.9 s');
t = 1000; ok(S('k', R, 800), 'on screen and unmoved for 1 s: it takes keys');
t = 1100; ok(!S('k', { left: 0, top: 140, width: 10, bottom: 160 }, 800), 'a card that moved starts its second again');
t = 3000; ok(!S('k', { left: 0, top: 900, width: 10, bottom: 950 }, 800), 'an off-screen card never takes keys');

// ---- page: title, favicon dot, notification, keys ----
let decs = [];
const A = win.OSRC_HUB_ATTN({ el, openDecs: () => decs });
const D = win.OSRC_HUB_DECIDE({ el, ic: () => new El('i'), tags: () => new El('div'), flush() {}, get db() { return null; } });
store['osrc-hub-notify'] = '1';
const proj = (gen) => [{ id: 'p1', name: 'Garden app', exported_at: gen, lanes: [] }];
A.refresh(proj(1));
ok(doc.title === 'Outsourcerer Mission Control' && icon.href === 'data:image/svg+xml,orig', 'nothing waiting: the tab keeps its title and icon');
decs = [{ id: 'D1', owner: 's1', q: 'Keep the old planner?', options: ['Keep', 'Drop'] }];
doc.hidden = false; A.refresh(proj(2));
ok(doc.title === '(1) Mission Control' && icon.href === 'data:image/png;base64,DOT', 'one open question: "(1) Mission Control" and a dot on the favicon');
ok(notes.length === 0, 'no notification while the tab is visible');
decs.push({ id: 'D1', owner: 's2', q: 'Ship tonight?', options: ['Keep', 'Drop'] });
doc.hidden = true; A.refresh(proj(3));
ok(notes.length === 1 && notes[0].o.body === 'Garden app: something is waiting on you' && notes[0].o.tag, 'hidden tab + opted in: one grouped notification on the transition');
A.refresh(proj(4));
ok(notes.length === 1, 'no repeat while the same items keep waiting');
store['osrc-hub-notify'] = '0'; decs.push({ id: 'D2', owner: 's2', q: 'More?', options: ['a'] }); A.refresh(proj(5));
ok(notes.length === 1, 'never without the opt-in click');
const A2 = win.OSRC_HUB_ATTN({ el, openDecs: () => decs }); doc.listeners.keydown.pop();   // one page, one key handler
store['osrc-hub-notify'] = '1'; doc.hidden = true; A2.refresh(proj(6));
ok(notes.length === 1, 'never on first load');
const A3 = win.OSRC_HUB_ATTN({ el, openDecs: () => decs }); doc.listeners.keydown.pop();
A3.refresh([]); A3.refresh(proj(7));
ok(notes.length === 1, 'never on first load, even when limits or answers render before the projects arrive');

// Merged card: two sessions' D1 -> distinct ids (P5).
const card = { id: 's1', name: 'Garden app' };
const c1 = D.decCard(card, decs[0]), c2 = D.decCard(card, decs[1]);
const ids = [c1, c2].map((c) => [c.id].concat(c.all().map((x) => x.id).filter(Boolean)));
ok(c1.id !== c2.id && ids[0].every((i) => !ids[1].includes(i)), 'two sessions\' D1 on one merged card get distinct ids (' + c1.id + ', ' + c2.id + ')');
body.append(c1, c2); c2.rect = { left: 0, top: 400, width: 300, bottom: 500 };

// Keys
let e = key('n'); ok(doc.activeElement === c1 && e.defaultPrevented, 'n goes to the first waiting item');
e = key('n'); ok(doc.activeElement === c2, 'n again goes to the next');
e = key('p'); ok(doc.activeElement === c1, 'p goes back');
clock = 1800000000000; key('1', c1);
ok(!c1.querySelectorAll('.opt')[0].attrs['aria-pressed'] || c1.querySelectorAll('.opt')[0].attrs['aria-pressed'] === 'false', 'a key on a card just focused does nothing (not yet steady)');
clock += 1000; key('1', c1);
ok(c1.querySelectorAll('.opt')[0].attrs['aria-pressed'] === 'true', 'after one second unmoved, 1 picks the first option');
clock += 1000; key('2', c1);
ok(c1.querySelectorAll('.opt')[1].attrs['aria-pressed'] === 'true' && c1.querySelectorAll('.opt')[0].attrs['aria-pressed'] === 'false', '2 picks the second option');
const ta = c1.querySelector('textarea'); clock += 1000; key('1', ta);
ok(c1.querySelectorAll('.opt')[1].attrs['aria-pressed'] === 'true', 'keys are ignored in a text field');
c1.rect = { left: 0, top: 300, width: 300, bottom: 400 }; clock += 100; key('1', c1);
ok(c1.querySelectorAll('.opt')[1].attrs['aria-pressed'] === 'true', 'a card that just moved ignores keys');
let sent = 0; const go = c1.querySelector('.go'); go.listeners.click = [() => { sent++; }];
clock += 1000; key('1', c1); go.disabled = false; clock += 1000; key('Enter', c1);
ok(sent === 1, 'Enter sends the focused, steady card');
key('Enter', go); ok(sent === 1, 'Enter on a button is left to the browser');
key('?'); ok(body.querySelector('.kb-help') !== null, '? opens the keys help'); key('?'); ok(body.querySelector('.kb-help') === null, '? closes it');

// Bands
const lanesB = [{ id: 'x', short: 'Approve me', attention: 'approval' }, { id: 'y', short: 'Done one', attention: 'finished' }, { id: 'z', short: 'Busy one', attention: 'working' }, { id: 'w', short: 'Busy two', attention: 'working' }];
const pb = { id: 'pb', exported_at: 1, lanes: lanesB }; A.refresh([pb]);
const sec = A.bands(pb, lanesB, (l) => new El('div', 'tile', l.short), true);
const hs = sec.querySelectorAll('h3').map((h) => h.textContent), work = sec.querySelector('.band-work');
ok(hs.join('|') === 'Waiting on you (1)|Back from work (1)' && work && work.textContent === '2 lanes working: Busy one, Busy two', 'bands: waiting on you, back from work, working folded to one line');
const sec2 = A.bands(pb, lanesB, (l) => new El('div', 'tile', l.short), false);
ok(!/Approve me|Busy one/.test(sec2.textContent) && /1 approval held/.test(sec2.textContent), 'without a board the bands show counts, not lane names');

console.log('RESULTS: ' + pass + ' pass ' + fail + ' fail');
process.exit(fail ? 1 : 0);
