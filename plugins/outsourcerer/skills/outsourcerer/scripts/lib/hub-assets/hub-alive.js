// hub-alive.js: whether Mission Control is live, always visible. Loaded before the page script.
// It watches the page's own /api/ calls (a fetch wrapper; the page code is unchanged) and keeps one
// strip at the top of the page:
//   - "Live · updated Ns ago"; a call that fails or runs past 10 s shows the reason and the age of the
//     last good data; a 401/403 reads "Not live (HTTP 403)"; an export that keeps failing (the hub still
//     answers, with its last good lanes and export_error) reads "Not live: export failing since HH:MM"; a
//     restarted hub (warming) says it is showing the last saved state until its first export lands;
//   Lane alerts (stalls, unreviewed READY lanes, no watcher) are NOT listed here: one row per lane buried
//   the page (0.17.0). Home's "things need you" tile sums them per project as Claude's to-do (hub-home.js).
// On a 401/403 the main pane (not the strip) explains it and carries a Reopen button: POST /reopen
// with this tab's old key; the hub answers with the current page URL only for a key it retired.
// window.OSRC_HUB_ALIVE_NOW (tests) replaces the clock.
(function () {
  'use strict';
  if (window.OSRC_HUB_ALIVE) return;
  if (window.claude && window.claude.use) return;   // artifact mode reads the artifact db, not this hub
  const now = () => (typeof window.OSRC_HUB_ALIVE_NOW === 'function' ? window.OSRC_HUB_ALIVE_NOW() : Date.now());
  const T0 = Date.now();
  const S = { lastGood: 0, err: '', dead: false, pending: new Map(), seq: 0, projects: [], exportedAt: 0 };
  const hhmm = (ms) => { const d = new Date(ms); return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0'); };
  const ago = (ms) => { const s = Math.max(0, Math.round(ms / 1000)); if (s < 60) return s + 's'; const m = Math.round(s / 60); return m < 60 ? m + ' min' : Math.round(m / 60) + ' h'; };
  const isApi = (u) => { try { const x = new URL(typeof u === 'string' ? u : (u && u.url) || '', location.href); return x.origin === location.origin && x.pathname.indexOf('/api/') === 0; } catch (e) { return false; } };

  const realFetch = window.fetch ? window.fetch.bind(window) : null;
  if (realFetch) {
    window.fetch = function (input, init) {
      if (!isApi(input)) return realFetch(input, init);
      const id = ++S.seq; S.pending.set(id, now());
      const done = () => { S.pending.delete(id); paint(); };
      return realFetch(input, init).then((r) => {
        done();
        if (r.status === 401 || r.status === 403) { S.dead = true; S.err = 'HTTP ' + r.status; paint(); return r; }
        if (!r.ok) { S.err = 'Mission Control answered HTTP ' + r.status; paint(); return r; }
        S.dead = false; S.err = ''; S.lastGood = now(); paint();
        const path = (() => { try { return new URL(typeof input === 'string' ? input : input.url, location.href).pathname; } catch (e) { return ''; } })();
        if (path === '/api/projects') r.clone().json().then((j) => { if (j && Array.isArray(j.projects)) { S.projects = j.projects; S.exportedAt = (j.generated_at || 0) * 1000; S.exportErr = j.export_error ? String(j.export_error) : ''; S.errSince = (j.export_error_since || 0) * 1000; S.warming = j.warming === true; paint(); } }).catch(() => {});
        return r;
      }, (e) => {
        done();
        S.err = (e && e.name === 'AbortError') ? 'no answer within 15 s' : 'cannot reach Mission Control (' + ((e && e.message) || 'network error') + ')';
        paint(); throw e;
      });
    };
  }

  let bar = null, line = null;
  function build() {
    if (bar || !document.body) return;
    const st = document.createElement('style');
    st.textContent = '#osrc-alive{position:sticky;top:0;z-index:50;font:13px/1.4 var(--sans,system-ui,sans-serif);color:var(--ink,#1f1f1c);background:var(--paper,#fbfaf7);border-bottom:1px solid var(--line,#8f8a7e);padding:6px 16px}'
      + '#osrc-alive .al-line{display:flex;gap:8px;align-items:center;flex-wrap:wrap}#osrc-alive .al-dot{width:8px;height:8px;border-radius:50%;background:var(--dot-ok,#2f9e44);flex:none}'
      + '#osrc-alive.al-warn .al-dot{background:var(--down,#c92a2a)}#osrc-alive.al-slow .al-dot{background:var(--mark,#e8a400)}'
            + '.al-reopen{margin-top:14px;display:flex;gap:12px;align-items:center;flex-wrap:wrap}.al-reopen button{font:inherit;padding:6px 16px;border-radius:8px;border:1px solid var(--line,#8f8a7e);background:var(--card,#fff);color:var(--ink,#1f1f1c);cursor:pointer}'
      + '#osrc-alive code{font-family:var(--mono,ui-monospace,monospace)}';
    document.head.appendChild(st);
    bar = document.createElement('div'); bar.id = 'osrc-alive'; bar.setAttribute('role', 'status'); bar.setAttribute('aria-live', 'polite');
    line = document.createElement('div'); line.className = 'al-line';
    bar.append(line);
    document.body.insertBefore(bar, document.body.firstChild);
  }

  function oldKey() { try { return sessionStorage.getItem('osrc-hub-t') || ''; } catch (e) { return ''; } }
  function reopen(note) {
    note.textContent = 'Reopening…';
    return realFetch('/reopen', { method: 'POST', headers: { 'X-Hub-Old-Token': oldKey() } })
      .then((r) => r.json().then((j) => ({ r, j })))
      .then(({ r, j }) => { if (r.ok && j && typeof j.url === 'string' && j.url.indexOf('/?t=') === 0) { location.href = j.url; } else { note.textContent = (j && j.text) || 'Run outsourcerer mc to open the current Mission Control.'; } })
      .catch(() => { note.textContent = 'Mission Control is not answering. Run outsourcerer mc.'; });
  }
  // The main pane carries the explanation and the one Reopen button; re-added after any re-render.
  function mainReopen() {
    const main = document.getElementById('main') || document.getElementById('welcome');
    if (!main || main.querySelector('.al-reopen')) return;
    const box = document.createElement('div'); box.className = 'al-reopen';
    const btn = document.createElement('button'); btn.type = 'button'; btn.textContent = 'Reopen';
    const note = document.createElement('span'); note.className = 'al-note';
    btn.addEventListener('click', () => reopen(note));
    box.append(btn, note); main.appendChild(box);
  }

  function setLoadingText(h, p) {   // main pane only: the rail and the strip keep their one line
    const w = document.getElementById('welcome');
    if (w && w.querySelector('h1')) { w.querySelector('h1').textContent = h; const q = w.querySelector('p'); if (q) q.textContent = p; }
  }


  function paint() {
    build(); if (!bar) return;
    const t = now(); let slow = 0;
    S.pending.forEach((t0) => { slow = Math.max(slow, t - t0); });
    const good = S.lastGood ? 'last good data ' + ago(t - S.lastGood) + ' ago' : 'no data yet';
    let text, cls = '';
    if (S.dead) { text = 'Not live (' + S.err + ')'; cls = 'al-warn'; }
    else if (S.err) { text = 'Not live: ' + S.err + ' · ' + good; cls = 'al-warn'; }
    else if (S.exportErr) { text = 'Not live: export failing since ' + hhmm(S.errSince || t) + (S.exportedAt ? ' · lane data from ' + ago(t - S.exportedAt) + ' ago' : ''); cls = 'al-warn'; }
    else if (S.warming) { text = 'Starting: showing the last saved state' + (S.exportedAt ? ' from ' + ago(t - S.exportedAt) + ' ago' : '') + ' until the first export finishes'; cls = 'al-slow'; }
    else if (slow >= 10000) { text = 'Waiting for Mission Control (' + ago(slow) + ') · ' + good; cls = 'al-slow'; }
    else if (S.lastGood) { text = 'Live · updated ' + ago(t - S.lastGood) + ' ago' + (S.exportedAt && t - S.exportedAt > 300000 ? ' · lane data from ' + ago(t - S.exportedAt) + ' ago' : ''); }
    else if (!S.seq && Date.now() - T0 > 3000) { text = 'Not live: this tab has no key. Run "outsourcerer mc" to open the current Mission Control'; cls = 'al-warn'; }
    else text = 'Connecting to Mission Control…';
    bar.className = cls;
    line.textContent = ''; const dot = document.createElement('span'); dot.className = 'al-dot'; const tx = document.createElement('span'); tx.className = 'al-text'; tx.textContent = text;
    line.append(dot, tx);
    if (S.dead) { setLoadingText('This tab is from an older Mission Control', 'Its key no longer opens the data. Press Reopen, or run "outsourcerer mc".'); mainReopen(); }
    else if (S.err && !S.lastGood) setLoadingText('Mission Control is not answering', S.err + '. Run "outsourcerer mc" to start or reopen it.');
  }

  window.OSRC_HUB_ALIVE = { state: S, paint, reopen };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', paint); else paint();
  setInterval(paint, 1000);
})();
