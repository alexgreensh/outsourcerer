/* hub-attn.js: what waits on you. The export gives every lane an `attention` (references/hub.md,
   "Attention"); this file puts lanes in three bands, counts what waits on you in the tab title and on the
   favicon, sends an opt-in browser notification and handles the keys (n p 1-9 Enter ?). Served from
   /assets/hub-attn.js (script-src 'self'); hub.html calls window.OSRC_HUB_ATTN(ctx). No network. */
(function () {
  'use strict';
  const YOU = ['approval', 'question', 'proof', 'review', 'stalled', 'limit'], BACK = ['ready', 'failed', 'finished'];
  const LABEL = { approval: 'approval held', question: 'question open', proof: 'proof stopped', review: 'review has no verdict',
    stalled: 'stalled after a nudge', limit: 'limit hit', ready: 'ready for review', failed: 'failed', finished: 'finished', working: 'working' };
  const bandOf = (a) => (YOU.includes(a) ? 'you' : BACK.includes(a) ? 'back' : 'work');
  const HEADLINE = 'something is waiting on you', STEADY_MS = 1000, NOTE_KEY = 'osrc-hub-notify';

  // Lanes move band only once their new band held for one more export (a flicker never reshuffles the page).
  // update() -> {count, fresh}: waiting-on-you items now, and the projects with an item that was not
  // waiting at the last export (empty on the first call: nothing is "new" on first load).
  function Tracker() {
    const st = {}; let gen = null, prev = null;
    function update(projects, openDecs) {
      const g = projects.map((p) => p.exported_at || 0).join(',');
      if (g !== gen) {
        gen = g; const live = {};
        projects.forEach((p) => (p.lanes || []).forEach((l) => {
          const k = p.id + '\n' + l.id, b = bandOf(l.attention), s = st[k]; live[k] = 1;
          if (!s) st[k] = { band: b, cand: null };
          else if (b === s.band) s.cand = null;
          else if (s.cand === b) { s.band = b; s.cand = null; } else s.cand = b;
        }));
        Object.keys(st).forEach((k) => { if (!live[k]) delete st[k]; });
      }
      const items = {}, fresh = [];
      projects.forEach((p) => {
        (p.lanes || []).forEach((l) => { if (band(p, l) === 'you') items['l:' + p.id + '--' + l.id] = p; });
        openDecs(p).forEach((d) => { items['d:' + (d.owner || p.id) + '--' + d.id] = p; });
      });
      if (prev) Object.keys(items).forEach((k) => { if (!prev[k] && !fresh.includes(items[k])) fresh.push(items[k]); });
      prev = items;
      return { count: Object.keys(items).length, fresh };
    }
    const band = (p, l) => { const s = st[p.id + '\n' + l.id]; return s ? s.band : bandOf(l.attention); };
    return { update, band };
  }

  // Grouped, opt-in, only while the tab is hidden; project names and a fixed headline, never lane output.
  function noteText(fresh) {
    const names = fresh.map((p) => String(p.name || 'A project').replace(/\s+/g, ' ').slice(0, 60));
    return (names.length > 3 ? names.slice(0, 3).join(', ') + ' and ' + (names.length - 3) + ' more' : names.join(', ')) + ': ' + HEADLINE;
  }

  // A key acts on a card only once it has been on screen and unmoved for about a second.
  function Steady(now) {
    let s = null;
    return function steady(key, r, vh) {
      const t = now(), on = r && r.width > 0 && r.bottom > 0 && r.top < vh;
      if (!on) { s = null; return false; }
      if (!s || s.key !== key || Math.abs(s.x - r.left) > 1 || Math.abs(s.y - r.top) > 1) { s = { key, x: r.left, y: r.top, t }; return false; }
      return t - s.t >= STEADY_MS;
    };
  }
  const typing = (t) => !!t && (/^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName || '') || t.isContentEditable);

  window.OSRC_HUB_ATTN = function (ctx) {
    const { el, openDecs } = ctx, doc = document, tr = Tracker(), steady = Steady(() => Date.now());
    const store = { get: () => { try { return localStorage.getItem(NOTE_KEY) === '1'; } catch (e) { return false; } },
      set: (v) => { try { localStorage.setItem(NOTE_KEY, v ? '1' : '0'); } catch (e) {} } };
    const title0 = doc.title, icon = doc.querySelector('link[rel="icon"]'), icon0 = icon ? icon.href : '';
    let target = null, help = null, shown = -1;

    function favicon(n) {
      if (!icon || (n > 0) === (shown > 0)) return; shown = n;
      if (!n) { icon.href = icon0; return; }
      const c = doc.createElement('canvas'); c.width = c.height = 64; const g = c.getContext && c.getContext('2d'); if (!g) return;
      g.font = '52px serif'; g.textBaseline = 'top'; g.fillText('\u{1FA84}', 4, 6);
      g.beginPath(); g.arc(50, 14, 12, 0, 2 * Math.PI); g.fillStyle = '#e5484d'; g.fill(); g.lineWidth = 3; g.strokeStyle = '#ffffff'; g.stroke();
      icon.href = c.toDataURL('image/png');
    }
    function refresh(projects) {
      const r = tr.update(projects, openDecs);
      doc.title = r.count ? '(' + r.count + ') Mission Control' : title0; favicon(r.count);
      if (r.fresh.length && doc.hidden && store.get() && window.Notification && Notification.permission === 'granted') {
        try { new Notification('Mission Control', { body: noteText(r.fresh), tag: 'osrc-mc-waiting' }); } catch (e) {}
      }
      return r;
    }

    // Three bands: waiting on you, back from work, working (one line). `named` false keeps a page with no
    // board to plain counts (lane names are not shown without one).
    function bands(p, lanes, laneTile, named) {
      const by = { you: [], back: [], work: [] }; lanes.forEach((l) => by[tr.band(p, l)].push(l));
      const sec = el('section', 'bands'); sec.append(el('h2', null, 'Lanes')); const wrap = el('div', 'themes');
      const kinds = (list) => Object.entries(list.reduce((a, l) => { const k = LABEL[l.attention] || 'working'; a[k] = (a[k] || 0) + 1; return a; }, {})).map(([k, n]) => n + ' ' + k).join(', ');
      [['you', 'Waiting on you', 0], ['back', 'Back from work', 6]].forEach(([k, t, cap]) => {
        const list = by[k]; if (!list.length) return;
        const box = el('div', 'card theme band-' + k), h = el('h3'); h.append(el('span', null, t + ' (' + list.length + ')')); box.append(h);
        if (!named) { box.append(el('p', 'sub', kinds(list))); wrap.appendChild(box); return; }
        const grid = el('div', 'lanes');
        (cap ? list.slice(0, cap) : list).forEach((l) => {
          const c = laneTile(l); c.append(el('span', 'mono attn', LABEL[l.attention] || ''));
          if (k === 'you') { c.dataset.wait = 'l:' + p.id + '--' + l.id; c.tabIndex = -1; }
          grid.appendChild(c);
        });
        box.append(grid); if (cap && list.length > cap) box.append(el('p', 'sub', 'and ' + (list.length - cap) + ' more'));
        wrap.appendChild(box);
      });
      sec.appendChild(wrap);
      if (by.work.length) {
        const nm = by.work.slice(0, 5).map((l) => l.short || l.id);
        sec.append(el('p', 'sub band-work', by.work.length + (by.work.length === 1 ? ' lane working' : ' lanes working')
          + (named ? ': ' + nm.join(', ') + (by.work.length > 5 ? ' and ' + (by.work.length - 5) + ' more' : '') : '')));
      }
      return sec;
    }

    // ---- keys ----
    const waits = () => [...doc.querySelectorAll('[data-wait]')];
    const cardOf = () => (target && waits().find((c) => c.dataset.wait === target)) || null;
    function move(d) {
      const all = waits(); if (!all.length) return;
      const i = all.findIndex((c) => c.dataset.wait === target), c = all[i < 0 ? (d > 0 ? 0 : all.length - 1) : (i + d + all.length) % all.length];
      target = c.dataset.wait; c.focus({ preventScroll: true }); c.scrollIntoView({ block: 'center' });
    }
    const ready = (c) => !!c && steady(c.dataset.wait, c.getBoundingClientRect(), window.innerHeight);
    setInterval(() => { const c = cardOf(); if (c && !doc.hidden) ready(c); }, 200);   // keeps the "unmoved" clock running
    function toggleHelp() {
      if (help) { help.remove(); help = null; return; }
      help = el('div', 'card kb-help'); help.setAttribute('role', 'dialog'); help.setAttribute('aria-label', 'Keys');
      const ul = el('ul'); [['n / p', 'next or previous thing waiting on you'], ['1 - 9', 'pick an option on that question'], ['Enter', 'send the answer'], ['?', 'show or hide this']]
        .forEach(([k, t]) => { const li = el('li'); li.append(el('b', 'mono', k), document.createTextNode(' ' + t)); ul.append(li); });
      const nb = el('button', 'go', store.get() ? 'Turn off notifications' : 'Notify me when something starts waiting');
      nb.type = 'button';
      nb.addEventListener('click', () => {
        if (store.get()) { store.set(false); nb.textContent = 'Notify me when something starts waiting'; return; }
        if (!window.Notification) { nb.textContent = 'This browser has no notifications'; return; }
        Promise.resolve(Notification.requestPermission()).then((r) => { store.set(r === 'granted'); nb.textContent = r === 'granted' ? 'Turn off notifications' : 'Notifications are blocked for this page'; });
      });
      help.append(el('h3', null, 'Keys'), ul, el('p', 'sub', 'Only while the tab is in the background, and only the project name.'), nb);
      doc.body.appendChild(help);
    }
    function onKey(e) {
      if (e.ctrlKey || e.metaKey || e.altKey || e.isComposing || typing(e.target)) return;
      const k = e.key, c0 = e.target && e.target.closest ? e.target.closest('[data-wait]') : null;
      if (c0) target = c0.dataset.wait;
      if (k === '?') { toggleHelp(); e.preventDefault(); return; }
      if (k === 'n' || k === 'p') { move(k === 'n' ? 1 : -1); e.preventDefault(); return; }
      const c = cardOf(); if (!c) return;
      if (/^[1-9]$/.test(k)) { if (!ready(c)) return; const b = c.querySelectorAll('.opt')[Number(k) - 1]; if (b) { b.click(); e.preventDefault(); } return; }
      if (k === 'Enter' && e.target === c) { if (!ready(c)) return; const g = c.querySelector('.go'); if (g && !g.disabled) { g.click(); e.preventDefault(); } }
    }
    doc.addEventListener('keydown', onKey);
    return { refresh, bands, onKey, band: tr.band };
  };
  window.OSRC_HUB_ATTN.internals = { Tracker, Steady, noteText, bandOf, typing };
})();
