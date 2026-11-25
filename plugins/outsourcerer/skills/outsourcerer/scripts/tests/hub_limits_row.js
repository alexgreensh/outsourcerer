// Render the Mission Control limits rows with the page's own renderLimits (lib/hub.html) and print
// each row's visible text: "<id>\t<state dot>\t<the row's limit text>\t<the whole row's text>". Input on stdin: the
// limits array the page receives (what _osrc_hub_limits exports). Hover cards are not rendered.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const page = fs.readFileSync(path.join(__dirname, '../lib/hub.html'), 'utf8');
const cut = (a, b) => { const i = page.indexOf(a), j = page.indexOf(b, i); if (i < 0 || j < 0) throw new Error('hub.html changed: ' + a); return page.slice(i, j); };
const src = cut('  const LSTATE = ', '\n') + '\n' + cut('  function renderLimits()', '  const grown = ');

function node(tag) {
  const n = { tag, className: '', textContent: '', children: [], dataset: {}, style: {}, attrs: {},
    setAttribute(k, v) { this.attrs[k] = v; }, addEventListener() {},
    append(...xs) { xs.forEach((x) => this.children.push(typeof x === 'string' ? { textContent: x, children: [] } : x)); },
    appendChild(x) { this.children.push(x); return x; }, replaceChildren() { this.children = []; } };
  return n;
}
const text = (n) => (n.children.length ? n.children.map(text).join('') : String(n.textContent || ''));
const ids = { llist: node('div'), lstamp: node('span') };
const ctx = {
  limits: JSON.parse(fs.readFileSync(0, 'utf8')), plansChecked: 0, db: null, H: null, window: {},
  $: (id) => ids[id] || null,
  el: (tag, cls, t) => { const e = node(tag); if (cls) e.className = cls; if (t != null) e.textContent = t; return e; },
  document: { createTextNode: (t) => ({ textContent: t, children: [] }) },
  ic: () => node('i'), hlogo: () => node('span'), pop() {}, staleCheck() {}, limitsOpen: () => true,
};
vm.runInNewContext(src + '\nrenderLimits();', ctx);
ids.llist.children.filter((r) => r.className === 'lrow').forEach((r) => {
  const dot = r.children.find((c) => /^dot /.test(c.className));
  const lf = r.children.find((c) => c.className === 'lf');
  process.stdout.write([r.id.replace(/^lim-/, ''), dot.className.slice(4), text(lf), r.children.map(text).join(' ')].join('\t') + '\n');
});
