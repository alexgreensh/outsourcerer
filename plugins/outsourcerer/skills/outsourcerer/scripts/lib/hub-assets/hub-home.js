/* Mission Control Home, ported from the approved sessions/2026-11-13-autonomy/hub/mission-control.html.
   Lives outside hub.html so the page stays under the 1,000-line rule; served by `hub serve` from
   /assets/hub-home.js (script-src 'self'). hub.html calls window.OSRC_HUB_HOME(ctx) with getters for
   its live state and the helpers it already has, and gets back the Home renderer, the Mark done flow
   and the stale-stamp Refresh button. If this file fails to load, hub.html falls back to the project view. */
(function () {
  window.OSRC_HUB_HOME = function (ctx) {
    const { $, el, ic, pri, paint, openDecs, byWeight, STATUS_TXT } = ctx;
    const isTop = (d) => d.weight === 'Critical' || d.weight === 'High';

    // ---- Undo toast (6 s) -------------------------------------------------------------------
    let utoastT = null, undoUntil = 0;
    function utoast(msg, undo) {
      // A late info message (e.g. a Refresh finishing) never takes a live Undo away from the user.
      if (!undo && Date.now() < undoUntil) return;
      undoUntil = undo ? Date.now() + 6000 : 0;
      const box = $('utoast') || (() => { const t = el('div', 'toast utoast'); t.id = 'utoast'; t.setAttribute('role', 'status'); document.body.appendChild(t); return t; })();
      box.replaceChildren(el('span', null, msg));
      if (undo) { const u = el('button', null, 'Undo'); u.type = 'button'; u.addEventListener('click', (e) => { e.stopPropagation(); box.hidden = true; undoUntil = 0; undo(); }); box.appendChild(u); }
      box.hidden = false; clearTimeout(utoastT); utoastT = setTimeout(() => { box.hidden = true; }, 6000);
    }

    // ---- Mark done from the rail (Alex 11:58) ------------------------------------------------
    // Writes only through the viewer's own click. shippedBy:"user" tells every orchestrator to leave the
    // status alone; Move back clears it so the build can report again. Local mode: the adapter turns
    // db.doc('projects/<id>').update() into POST /api/projects/<id>/status.
    async function setShipped(p, on) {
      const db = ctx.db; if (!db) return;
      // A pull since the click (Undo comes 0-6 s later) replaces every project object; act on the live one.
      p = ctx.projects.find((x) => x.id === p.id) || p;
      const prev = { status: p.status, shippedAt: p.shippedAt, shippedBy: p.shippedBy, prevStatus: p.prevStatus };
      const now = new Date().toISOString();
      const patch = on
        ? { status: 'shipped', shippedAt: now, shippedBy: 'user', prevStatus: p.status || 'building', updatedAt: now }
        : { status: (p.prevStatus && p.prevStatus !== 'shipped') ? p.prevStatus : 'building', shippedBy: null, shippedAt: null, updatedAt: now };
      Object.assign(p, patch); ctx.renderRail(); ctx.renderMain();
      const ref = db.doc('projects/' + p.id);
      try { try { await ref.update(patch); } catch (e1) { if (e1 && e1.final) throw e1; await ref.update(patch); } }
      catch (e) {
        Object.assign(p, prev); ctx.renderRail(); ctx.renderMain();
        const code = (e && (e.code || e.message)) || '';
        if (/not_granted|not_writer|permission|forbidden|denied|HTTP 403/i.test(code)) { ctx.canWrite = false; ctx.renderRail(); utoast('You can view this board but not change it.'); }
        else utoast('Not saved, try again.');
        return;
      }
      if (on) utoast('Moved ' + p.name + ' to Shipped', () => setShipped(p, false));
      else utoast(p.name + ' is back in Running now');
    }

    // ---- Refresh on stale stamps (>45 min) ----------------------------------------------------
    // Artifact mode asks the orchestrator through doc refresh/<kind--id>; its 5-minute check re-reads that
    // project or the limits. Pending asks are remembered for 10 min so re-renders keep the state.
    // Local mode re-exports right away (POST /api/refresh) and re-pulls, so nothing stays pending.
    const asked = {};
    function refreshBtn(st, old) {
      let rb = st.querySelector('.rfr'); const key = st.dataset.rk;
      if (!(old && key && ctx.db && ctx.canWrite !== false)) { if (rb) rb.remove(); return; }
      if (!rb) { rb = el('button', 'rfr'); rb.type = 'button'; rb.addEventListener('click', (e) => { e.stopPropagation(); askRefresh(key, rb); }); st.append(rb); }
      const pend = asked[key] && Date.now() - asked[key] < 600000;
      rb.disabled = !!pend; rb.replaceChildren(ic('refresh-cw'), document.createTextNode(pend ? 'Refreshing…' : 'Refresh'));
      rb.title = pend ? 'Asked. The orchestrator updates this within about 5 minutes.' : (ctx.mode === 'local' ? 'Read this project again now' : 'Ask the orchestrator to read this again now');
      paint();
    }
    async function askRefresh(key, rb) {
      asked[key] = Date.now(); rb.disabled = true; rb.replaceChildren(ic('refresh-cw'), document.createTextNode('Refreshing…')); paint();
      const [kind, id] = key.split(':');
      try { await ctx.db.doc('refresh/' + key.replace(':', '--')).set({ kind, id: id || '', at: new Date().toISOString() }); }
      catch (e) { delete asked[key]; if (rb.isConnected) { rb.disabled = false; rb.replaceChildren(ic('refresh-cw'), document.createTextNode('Not sent, try again')); paint(); } return; }
      if (ctx.mode === 'local') {
        delete asked[key]; ctx.staleCheck();
        const still = document.querySelector('[data-rk="' + key + '"].stale');
        if (still) utoast('Read again just now. Nothing newer from this build yet.');
      }
    }

    // ---- Home: the first screen. One glance answers "what needs me". --------------------------
    function ptile(p) {
      const go = ctx.go; const ds = openDecs(p);
      const t = el('article', 'card ptile' + (p.status === 'paused' ? ' paused' : '') + (ds.length ? ' waits' : '')); t.id = 'tile-' + p.id;
      const top = el('div', 'pt-top');
      const nb = el('button', 'pt-name', p.name); nb.type = 'button'; nb.addEventListener('click', (e) => { e.stopPropagation(); go(p.id); });
      const stt = ds.length ? ['st-wait', 'Waiting on you'] : [p.status === 'paused' ? 'st-paused' : p.status === 'shipped' ? 'st-shipped' : '', STATUS_TXT[p.status] || 'Building'];
      top.append(nb, el('span', 'pill ' + stt[0], stt[1])); t.append(top);
      if (p.tagline) t.append(el('p', 'pt-tag', p.tagline));
      const pr = el('div', 'pt-prog'); const bar = el('div', 'bar'); const fill = el('span'); bar.appendChild(fill);
      bar.setAttribute('role', 'progressbar'); bar.setAttribute('aria-valuenow', String(p.pct || 0)); bar.setAttribute('aria-valuemin', '0'); bar.setAttribute('aria-valuemax', '100'); bar.setAttribute('aria-label', p.name + ' progress');
      pr.append(bar, el('span', 'pct', (p.pct || 0) + '%')); t.append(pr);
      requestAnimationFrame(() => { fill.style.width = (p.pct || 0) + '%'; });
      const meta = el('div', 'pt-meta');
      if (p.eta) { const e = el('span'); e.append(ic('rocket'), document.createTextNode('Ships ' + p.eta)); meta.append(e); }
      if (p.updated) {
        const u = el('span', 'lst'); u.dataset.at = p.updatedAt || ''; u.dataset.live = (p.status === 'shipped' || p.status === 'paused') ? '' : '1';
        u.dataset.words = '1'; u.dataset.rk = 'project:' + p.id; u.dataset.base = (p.status === 'paused' ? 'Paused since ' : 'Updated ') + p.updated;
        u.append(ic(p.status === 'paused' ? 'pause' : 'clock'), el('span', 'lstx', u.dataset.base)); meta.append(u);
      }
      if (meta.children.length) pr.append(meta);
      const topN = ds.filter(isTop).length;
      const rest = ds.filter((d) => !isTop(d));
      if (topN) t.append(el('p', 'pt-top5', topN + ' in top priority, above'));
      if (rest.length) {
        const ul = el('ul', 'pt-decs');
        rest.slice(0, 2).forEach((d) => { const li = el('li'); const b = el('button', 'dbtn'); b.type = 'button'; b.append(pri(d.weight), el('span', null, d.short || d.q)); b.title = d.q || ''; b.addEventListener('click', (e) => { e.stopPropagation(); go(p.id, d.id); }); li.append(b); ul.append(li); });
        t.append(ul);
        if (rest.length > 2) { const m = el('button', 'pt-more', 'and ' + (rest.length - 2) + ' more'); m.type = 'button'; m.addEventListener('click', (e) => { e.stopPropagation(); go(p.id); }); t.append(m); }
      } else if (!topN) { const n = el('p', 'pt-none'); n.append(ic('circle-check'), document.createTextNode('Nothing waiting on you.')); t.append(n); }
      t.addEventListener('click', () => go(p.id));
      return t;
    }

    function renderHome() {
      const projects = ctx.projects, db = ctx.db, go = ctx.go;
      const main = $('main'); ctx.hide(); main.replaceChildren(); ctx.resetForms();
      const live = projects.filter((p) => p.status !== 'shipped');
      const running = live.filter((p) => p.status !== 'paused').concat(live.filter((p) => p.status === 'paused'));
      const shipped = projects.filter((p) => p.status === 'shipped');
      const all = []; running.forEach((p) => openDecs(p).forEach((d) => all.push({ p, d })));
      const ph = el('header', 'ph home');
      const waitingOn = new Set(all.map((x) => x.p.id)).size;
      const err = ctx.pullErr;
      const head = !projects.length ? (err ? 'Cannot reach the local hub' : db ? 'No projects yet' : 'Sign in to see your projects')
        : all.length ? all.length + (all.length === 1 ? ' decision waits on you' : ' decisions wait on you') : 'Nothing is waiting on you';
      const sub = !projects.length ? (err ? 'Is hub serve running? (' + err + ')' : db ? 'An orchestrator adds its project here when it starts a build.' : 'Open this board on claude.ai while signed in.')
        : all.length ? 'Across ' + waitingOn + (waitingOn === 1 ? ' project.' : ' projects.') : 'Everything is moving.';
      ph.append(el('h1', null, head), el('p', 'lede', sub)); main.append(ph);
      const top = all.filter((x) => isTop(x.d)).sort((a, b) => byWeight(a.d, b.d));
      if (top.length) {
        const sec = el('section', 'card toppri'); const h = el('h2'); h.id = 'tp-h'; h.append(ic('hand'), el('span', null, 'These are top-priority decisions for you right now.')); sec.setAttribute('aria-labelledby', 'tp-h');
        const ul = el('ul', 'tplist');
        top.forEach(({ p, d }) => {
          const li = el('li', 'tprow'); const q = el('div', 'tpq'); q.append(el('span', 'tpn', p.name), el('span', 'tpt', d.short || d.q));
          // Only the first Decide is filled; the rest are ghost buttons so the eye lands on one call to action.
          const b = el('button', 'go' + (ul.children.length ? ' ghost' : '')); b.type = 'button'; b.id = 'tp-' + p.id + '-' + d.id; b.append(document.createTextNode('Decide'), ic('arrow-right')); b.setAttribute('aria-label', 'Decide: ' + (d.short || d.q));
          b.addEventListener('click', () => go(p.id, d.id));
          const chev = ic('chevron-right'); chev.setAttribute('class', 'chev');
          li.append(pri(d.weight), q, b, chev); ul.append(li);
          li.addEventListener('click', (e) => { if (window.innerWidth <= 520 && e.target !== b) go(p.id, d.id); });
        });
        sec.append(h, ul); main.append(sec);
      }
      const list = running.length ? running : shipped;
      if (list.length) {
        const sec = el('section'); sec.append(el('h2', null, running.length ? 'Your projects' : 'Shipped'));
        const grid = el('div', 'ptiles' + (list.length === 1 ? ' one' : '')); list.forEach((p) => grid.append(ptile(p)));
        sec.append(grid); main.append(sec);
      }
      if (running.length && shipped.length) main.append(el('p', 'foot', shipped.length + ' shipped, listed under Shipped in the sidebar.'));
      ctx.staleCheck(); paint();
    }

    return { renderHome, refreshBtn, setShipped, utoast };
  };
})();
