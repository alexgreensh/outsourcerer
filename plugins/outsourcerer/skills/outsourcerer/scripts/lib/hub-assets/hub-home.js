/* Mission Control Home, ported from an approved design mock.
   Lives outside hub.html so the page stays under the 1,000-line rule; served by `hub serve` from
   /assets/hub-home.js (script-src 'self'). hub.html calls window.OSRC_HUB_HOME(ctx) with getters for
   its live state and the helpers it already has, and gets back the Home renderer, the Mark done flow
   and the stale-stamp Refresh button. If this file fails to load, hub.html falls back to the project view. */
(function () {
  // ---- the page never prints an id or a stored renew string ------------------------------------
  // Same id rules as lib/hub-lanename.sh (_OSRC_HUB_IDLIKE_JQ): Outsourcerer session prefixes, "--<digits>"
  // hash joins, hex runs of 6+ holding a digit, a whole value that is a slug ending in a number.
  const IDLIKE = [/(^|[^A-Za-z0-9])(osrc|outsourcerer)-/i, /--[0-9]/,
    /(^|[^A-Za-z0-9])(?=[0-9a-fA-F]*[0-9])[0-9a-fA-F]{6,}(?![A-Za-z0-9])/, /^[a-z0-9]+([-_][a-z0-9]+)*[-_][0-9]+[a-z]?$/];
  const idlike = (s) => typeof s === 'string' && IDLIKE.some((r) => r.test(s));
  const HOURS = /\d+\s*h\s*\d+\s*m|^\s*(in\s+)?\d+\s*h\s*$/i;   // "92h 32m", "in 120h 6m": an old build's countdown
  const RDAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'], RMON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  // renewText(epoch s) -> "today · 18:40" | "tomorrow · 09:10" | "in 4 days · Thu 19 Nov" in the viewer's local time; "" when past.
  function renewText(sec, nowMs) {
    const t = new Date(sec > 1e11 ? sec : sec * 1000), now = new Date(nowMs || Date.now());
    if (!(t.getTime() > now.getTime())) return '';
    const day = (x) => Date.UTC(x.getFullYear(), x.getMonth(), x.getDate()) / 86400000, pad = (n) => String(n).padStart(2, '0');
    const d = Math.round(day(t) - day(now)), hm = pad(t.getHours()) + ':' + pad(t.getMinutes());
    return d === 0 ? 'today · ' + hm : d === 1 ? 'tomorrow · ' + hm : 'in ' + d + ' days · ' + RDAY[t.getDay()] + ' ' + t.getDate() + ' ' + RMON[t.getMonth()];
  }
  function cleanLimit(l, nowMs) {
    const o = Object.assign({}, l);
    if (typeof o.renews_at === 'number' && o.renews_at > 0) o.renews = renewText(o.renews_at, nowMs) || null;
    else if (typeof o.renews !== 'string' || HOURS.test(o.renews)) delete o.renews;
    return o;
  }
  function sentenceCase(s) {
    const t = String(s || '').replace(/[-_]+/g, ' ').replace(/\s+/g, ' ').trim();
    return t ? t.charAt(0).toUpperCase() + t.slice(1).toLowerCase() : '';
  }
  function isPromptTitle(s) {
    if (typeof s !== 'string') return false;
    return s.split(' · ').some((part) => {
      const t = part.trim();
      return t.startsWith('[') || t.length > 40 || /READ BEFORE/i.test(t);
    });
  }
  function ageSpan(min) {
    if (!(min >= 0)) return '';
    return min < 60 ? Math.max(1, Math.floor(min)) + ' min' : min < 2880 ? Math.floor(min / 60) + ' h' : Math.floor(min / 1440) + ' days';
  }
  function cardStaleInfo(p, nowMs) {
    if (!p || p.status === 'shipped' || p.source === 'live') return null;   // derived from live lanes: current by construction
    const hasText = Boolean(p.cardStale || p.next || p.eta || (typeof p.pct === 'number' && isFinite(p.pct)));
    if (!hasText) return null;
    const lim = (typeof p.cardStaleMin === 'number' && isFinite(p.cardStaleMin)) ? p.cardStaleMin : 30;
    const now = nowMs || Date.now();
    const rep = Date.parse(p.reportedAt || '');
    const min = !isNaN(rep) ? Math.floor((now - rep) / 60000)
      : (typeof p.cardAgeMin === 'number' && isFinite(p.cardAgeMin) ? p.cardAgeMin : null);
    if (min == null) return p.cardStale ? { min: lim, text: 'Last update from its session: ' + ageSpan(lim) + ' ago' } : null;
    if (min < lim) return null;
    return { min, text: 'Last update from its session: ' + ageSpan(min) + ' ago' };
  }
  function decStaleInfo(p, d, nowMs) {
    if (!d || d.status === 'done') return null;
    const limH = (p && typeof p.decisionStaleH === 'number' && isFinite(p.decisionStaleH)) ? p.decisionStaleH : 2;
    const now = nowMs || Date.now();
    const raw = d.confirmedAt || d.askedAt || (p && p.reportedAt) || '';
    const ts = Date.parse(raw);
    if (isNaN(ts)) {
      if (!d.stale) return null;
      const h0 = Math.max(limH, Math.floor(d.staleHours || limH));
      const s0 = h0 >= 48 ? Math.floor(h0 / 24) + ' days' : h0 + ' h';
      return { hours: h0, text: 'Not re-confirmed for ' + s0 + ', may be out of date' };
    }
    const ageH = (now - ts) / 3600000;
    if (!(ageH >= limH)) return null;
    const h = Math.max(limH, Math.floor(ageH));
    const s = h >= 48 ? Math.floor(h / 24) + ' days' : h + ' h';
    return { hours: h, text: 'Not re-confirmed for ' + s + ', may be out of date' };
  }
  // A project name keeps its human parts ("Widget Core · total-recall-85" -> "Widget Core").
  // Prompt-text titles (starting with '[', over 40 chars, or containing 'READ BEFORE') fall back to the folder name in sentence case.
  function cleanName(s, fallback) {
    if (typeof s !== 'string') return fallback;
    const parts = s.split(' · ').filter((x) => x && !idlike(x));
    return parts.length ? parts.join(' · ') : fallback;
  }
  function cleanProject(p, nowMs) {
    const o = Object.assign({}, p);
    o.name = cleanName(o.name, 'Orchestrator session');
    if (isPromptTitle(o.name)) {
      const firstSeg = String(o.name).split(' · ').find((x) => x && !isPromptTitle(x) && !idlike(x));
      o.name = (o.folder && sentenceCase(o.folder)) || (firstSeg && sentenceCase(firstSeg)) || 'Orchestrator session';
    }
    if (Array.isArray(o.lanes)) o.lanes = o.lanes.map((l) => (idlike(l.short) || !l.short ? Object.assign({}, l, { short: l.model ? 'Lane · ' + l.model : 'Lane' }) : l));
    if (cardStaleInfo(o, nowMs)) { o.cardStale = true; delete o.next; }
    return o;
  }
  // "Ships X" for a tile/hover: an eta value may already carry the verb ("Ship target 17:00 today")
  // or be a bare status word ("done"); never render "Ships Ship …" or "Ships done". "" hides the line.
  function shipEta(eta) {
    const et = String(eta || '').replace(/^ships?\s+/i, '').trim();
    return et && !/^(done|shipped|live|cancelled?)$/i.test(et) ? 'Ships ' + et : '';
  }
  // sessionStamp(p) -> ms epoch of when the project's SESSION last reported its content:
  // card reportedAt, else a parseable board.updated, else last real activity (updatedAt).
  // Never the export/serve stamp — an 'Updated' label must say when the session's words
  // were last reported, not when this page was built. null when nothing is known.
  function sessionStamp(p) {
    if (!p) return null;
    for (const v of [p.reportedAt, p.boardUpdated, p.updatedAt]) {
      const t = Date.parse(v || ''); if (!isNaN(t)) return t;
    }
    return null;
  }
  window.OSRC_HUB_CLEAN = { idlike, renewText, limit: cleanLimit, project: cleanProject, name: cleanName, sentenceCase, isPromptTitle, cardStale: cardStaleInfo, decStale: decStaleInfo, shipEta, sessionStamp };

  window.OSRC_HUB_HOME = function (ctx) {
    const { $, el, ic, pri, paint, openDecs, byWeight, stPill } = ctx;
    const isTop = (d) => d.weight === 'Critical' || d.weight === 'High';
    const grown = new Set();   // a tile's bar animates the first time only; re-renders set it directly
    // Tiles use a short stamp, local time, from the project's real last change
    // (updatedAt). The full stamp stays on the project page. Long stamps squeezed the bars and wrapped the stale pill.
    const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    // Local time, never UTC. "23:00" today, "yesterday 23:00", else "Mon 16 Nov, 09:10".
    const DAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    function localStamp(ms) {
      const d = new Date(ms), pad = (n) => String(n).padStart(2, '0'), hm = pad(d.getHours()) + ':' + pad(d.getMinutes());
      const day = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
      const diff = Math.round((day(new Date()) - day(d)) / 86400000);
      return diff === 0 ? hm : diff === 1 ? 'yesterday ' + hm : DAY[d.getDay()] + ' ' + d.getDate() + ' ' + MON[d.getMonth()] + ', ' + hm;
    }
    function shortStamp(iso, fallback) {
      const t = Date.parse(iso || ''); return isNaN(t) ? fallback : localStamp(t);
    }
    // Every 'Updated' on a project is the session's last report, never the export
    // stamp. projFresh draws the project-page stamp + stale hero line (same cardStale rule as
    // Home); etaAsOf dates a stale release line 'as of …'; freshText feeds the page footer.
    const freshText = (p) => { const ep = sessionStamp(p); return ep ? localStamp(ep) : String((p && p.updated) || 'not yet'); };
    function projFresh(p, host) {
      const ep = sessionStamp(p);
      if (p.updated || ep) {
        const st = el('p', 'stamp-top'); st.dataset.rk = 'project:' + p.id; st.dataset.at = ep ? new Date(ep).toISOString() : (p.updatedAt || '');
        st.dataset.live = p.status === 'shipped' ? '' : '1';
        st.append(ic('clock'), el('span', null, 'Updated ' + freshText(p))); host.prepend(st);
      }
      const cst = cardStaleInfo(p); if (cst) host.append(el('p', 'pt-stale', cst.text));
    }
    function etaAsOf(p) {
      if (!p || !p.eta || !cardStaleInfo(p)) return '';
      const bu = Date.parse(p.boardUpdated || ''), rep = Date.parse(p.reportedAt || '');
      const t = !isNaN(bu) ? localStamp(bu) : (!isNaN(rep) ? localStamp(rep) : String(p.boardUpdated || ''));
      return t ? 'as of ' + t : '';
    }

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

    // ---- Mark done from the rail --------------------------------------------------------------
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

    // One Mark done / Move back button, used in the rail card and the project page header (the header
    // copy is the one a phone or a keyboard can reach). Same click, same Undo, same shippedBy/shippedAt.
    function doneBtn(p, id, after) {
      if (!ctx.db || ctx.canWrite === false) return null;
      const shipped = p.status === 'shipped', k = el('button', 'hcact'); k.type = 'button'; k.id = id || (shipped ? 'back-' : 'chk-') + p.id;
      k.append(ic(shipped ? 'rotate-ccw' : 'check'), document.createTextNode(shipped ? 'Move back to running' : 'Mark done, move to Shipped'));
      k.addEventListener('click', (e) => { e.stopPropagation(); if (after) after(); setShipped(p, !shipped); });
      return k;
    }

    // ---- Refresh on stale stamps (>45 min) ----------------------------------------------------
    // Artifact mode asks the orchestrator through doc refresh/<kind--id>; its 5-minute check re-reads that
    // project or the limits. Pending asks are remembered for 10 min so re-renders keep the state.
    // Local mode re-exports right away (POST /api/refresh) and re-pulls, so nothing stays pending.
    const asked = {};
    // Plans for the Home tile: the tightest real reading heads it, every checked plan gets a line, lowest
    // first. A stale ok/low reading is already "unknown" (plan-overlay.jq), so it drops out; a stale
    // out/wait reading keeps its state on purpose (usage only rises, an empty plan is still empty) and
    // stays, so the tile stays hot. Checked plans with no percentage ("Free models") get a text line.
    function planReadings(limits) {
      const real = (limits || []).map((l) => ({ l, n: parseFloat(String(l.left || '')) })).filter((x) => isFinite(x.n) && x.l.state !== 'unknown').sort((a, b) => a.n - b.n);
      const lims = real.concat((limits || []).filter((l) => !isFinite(parseFloat(String(l.left || ''))) && l.left && ['ok', 'low'].includes(l.state)).map((l) => ({ l, n: NaN, t: l.left })));
      return { lim: real[0], lims, hot: lims.some((x) => x.l.state === 'out' || x.l.state === 'wait') };
    }
    function refreshBtn(st, old) {
      let rb = st.querySelector('.rfr'); const key = st.dataset.rk;
      if (!(old && key && ctx.db && ctx.canWrite !== false)) { if (rb) rb.remove(); return; }
      if (!rb) { rb = el('button', 'rfr'); rb.type = 'button'; rb.id = 'rfr-' + key.replace(/[^A-Za-z0-9_-]/g, '-') + (st.classList.contains('stamp-top') ? '-top' : ''); rb.addEventListener('click', (e) => { e.stopPropagation(); askRefresh(key, rb); }); st.append(rb); }
      const pend = asked[key] && Date.now() - asked[key] < 600000;
      rb.disabled = !!pend; rb.replaceChildren(ic('refresh-cw'), document.createTextNode(pend ? 'Refreshing…' : 'Refresh'));
      rb.title = pend ? 'Asked. The orchestrator updates this within about 5 minutes.' : (ctx.mode === 'local' ? 'Read this project again now' : 'Ask the orchestrator to read this again now');
      paint();
    }
    async function askRefresh(key, rb) {
      asked[key] = Date.now(); rb.disabled = true; rb.replaceChildren(ic('refresh-cw'), document.createTextNode('Refreshing…')); paint();
      const [kind, id] = key.split(':');
      try { await ctx.db.doc('refresh/' + key.replace(':', '--')).set({ kind, id: id || '', at: new Date().toISOString() }); }
      catch (e) { delete asked[key]; ctx.staleCheck(); utoast('Refresh failed. Try again.'); if (rb.isConnected) { rb.disabled = false; rb.replaceChildren(ic('refresh-cw'), document.createTextNode('Not sent, try again')); paint(); } return; }
      if (ctx.mode === 'local') {
        delete asked[key]; ctx.staleCheck();
        const still = document.querySelector('[data-rk="' + key + '"].stale');
        utoast(still ? 'Refreshed just now. No newer build activity.' : 'Refreshed just now.');
      }
    }

    // ---- Live summary line ---------------------------------------------------------------------
    // The tick rewrites p.summary from real lane state ("5 lanes: 3 building, 1 done") every 10 min. It sits under
    // the progress bar with the Updated stamp, in the stamp's type; the tagline stays the description. None, no line.
    function sumLine(p) {
      const s = typeof p.summary === 'string' ? p.summary.trim() : ''; if (!s) return null;
      const d = el('span', 'psum', s); d.id = 'psum-' + p.id;
      const at = shortStamp(p.summaryAt, ''); if (at) d.title = 'Lane summary as of ' + at;
      return d;
    }

    // ---- Progress -----------------------------------------------------------------------------
    // A project or lane that never reported progress has no pct: it shows no number and no bar. 0 is a real 0.
    const hasPct = (x) => typeof (x && x.pct) === 'number' && isFinite(x.pct);

    // ---- Live lanes ----------------------------------------------------------------------------
    // Every running card and rail entry lists its live lanes: name, model, what it is doing and for how long.
    // Export gives state (screen/job truth), startedAt and activeAt (epochs); old exports only had status.
    const LST = { working: 'working', approval: 'waiting for approval', question: 'asked a question', idle: 'idle',
      limit: 'hit a plan limit', failed: 'failed', unknown: 'state unknown' };
    const ENDED = ['Done', 'Merged', 'Failed', 'Canceled', 'Shipped', 'Closed'];
    function laneState(l) {
      if (l.state && LST[l.state]) return l.state;
      const s = String(l.status || '').toLowerCase();
      return s === 'idle' ? 'idle' : s === 'blocked' ? 'approval' : s === 'building' || !s ? 'working' : 'unknown';
    }
    const liveLanes = (p) => (p.lanes || []).filter((l) => !ENDED.includes(l.status) && l.state !== 'done');
    function dur(sec) {
      if (!(sec >= 0)) return '';
      const m = Math.floor(sec / 60), h = Math.floor(m / 60), d = Math.floor(h / 24);
      return m < 1 ? 'under a minute' : h < 1 ? m + ' min' : d < 1 ? h + ' h ' + (m % 60) + ' min' : d + ' d ' + (h % 24) + ' h';
    }
    function hhmm(t) { return localStamp(t * 1000); }
    // How long: a working lane counts from its start, a waiting or idle one from its last activity.
    function laneFor(l, st) {
      const t = st === 'working' ? (l.startedAt || l.activeAt) : (l.activeAt || l.startedAt);
      return t ? dur(Date.now() / 1000 - t) : '';
    }
    function laneList(p, compact) {
      const ls = liveLanes(p); if (!ls.length) return null;
      const ul = el('ul', compact ? 'rlanes' : 'pt-lanes'); ul.setAttribute('aria-label', 'Live lanes in ' + p.name);
      ls.forEach((l) => {
        const st = laneState(l), how = laneFor(l, st);
        const li = el('li', 'ln-' + st); li.id = (compact ? 'rl-' : 'pl-') + p.id + '-' + l.id;
        const ps = window.OSRC_HUB_PROOF ? window.OSRC_HUB_PROOF.stamp(l) : '';
        const txt = LST[st] + (how ? ', ' + how : '') + (ps ? ' · ' + ps : '');
        li.append(el('span', 'lnd'), el('span', 'lnn', l.short || l.id));
        if (!compact && l.model) li.append(el('span', 'lnm mono', l.model));
        li.append(el('span', 'lns', txt));
        li.title = [l.short || l.id, l.model, txt, l.startedAt ? 'started ' + hhmm(l.startedAt) : '', l.activeAt ? 'last activity ' + hhmm(l.activeAt) : ''].filter(Boolean).join(' · ');
        ul.append(li);
      });
      return ul;
    }

    // ---- Home: the first screen. One glance answers "what needs me". --------------------------
    const cmpDec = (a, b) => (decStaleInfo(a.p, a.d) ? 1 : 0) - (decStaleInfo(b.p, b.d) ? 1 : 0) || byWeight(a.d, b.d);
    function isQuiet(p) {
      if (!p || p.status === 'shipped') return false;
      const hasLive = p.liveLanes == null ? liveLanes(p).length > 0 : p.liveLanes > 0;
      if (hasLive) return false;
      if (openDecs(p).length > 0) return false;
      const limH = (typeof p.staleHours === 'number' && isFinite(p.staleHours)) ? p.staleHours : 24;
      const rep = Date.parse(p.reportedAt || '');
      if (!isNaN(rep) && (Date.now() - rep) < limH * 3600000) return false;
      return true;
    }
    // ---- Truth lines: the loud orchestrator alerts, each session's state, and the report's age ----------
    // (lib/hub-truth.sh). "lanes running, orchestrator idle N min" and "lane finished N min ago, nobody
    // picked it up" are the failures that cost the most time, so they sit on the tile itself.
    const LOUD = ['orch-idle', 'unpicked'];
    function truthLines(p) {
      const out = [];
      (Array.isArray(p.alerts) ? p.alerts : []).filter((a) => LOUD.includes(a.kind)).slice(0, 3)
        .forEach((a) => { const n = el('p', 'pt-stale'); n.append(ic('triangle-alert'), document.createTextNode(' ' + a.text)); out.push(n); });
      const os = Array.isArray(p.orchestrators) ? p.orchestrators : [];
      if (os.length > 1) out.push(el('p', 'pt-tag', 'Sessions: ' + os.map((o) => (o.state === 'working' ? 'working' : o.state === 'gone' ? 'gone' : 'idle ' + ageSpan(o.idleMin || 0)) + (o.lanes ? ' (' + o.lanes + (o.lanes === 1 ? ' lane)' : ' lanes)') : '')).join(' · ')));
      const r = p.reported;
      if (p.source === 'live' && r && typeof r.ageMin === 'number') {
        const said = [r.status, typeof r.pct === 'number' ? r.pct + '%' : '', r.next].filter(Boolean).join(', ');
        if (said) out.push(el('p', 'pt-tag', 'Its session last said ' + ageSpan(Math.max(1, r.ageMin)) + ' ago: ' + said));
      }
      return out;
    }
    function ptile(p) {
      const go = ctx.go; const ds = openDecs(p);
      const t = el('article', 'card ptile' + (p.status === 'paused' ? ' paused' : '') + (ds.length ? ' waits' : '')); t.id = 'tile-' + p.id;
      const top = el('div', 'pt-top');
      const nb = el('button', 'pt-name', p.name); nb.type = 'button'; nb.id = 'ptn-' + p.id; nb.addEventListener('click', (e) => { e.stopPropagation(); go(p.id); });
      top.append(nb, stPill(p)); t.append(top);
      if (p.tagline) t.append(el('p', 'pt-tag', p.tagline));
      const cst = cardStaleInfo(p);
      if (cst) t.append(el('p', 'pt-stale', cst.text));
      else if (p.next) { const n = el('p', 'pt-next'); n.append(el('b', null, 'Next'), el('span', null, p.next)); t.append(n); }   // from hub report --next
      truthLines(p).forEach((n) => t.append(n));
      const pr = el('div', 'pt-prog' + (hasPct(p) ? '' : ' nopct')); t.append(pr);
      if (hasPct(p)) {
        const bar = el('div', 'bar'); const fill = el('span'); bar.appendChild(fill);
        bar.setAttribute('role', 'progressbar'); bar.setAttribute('aria-valuenow', String(p.pct)); bar.setAttribute('aria-valuemin', '0'); bar.setAttribute('aria-valuemax', '100'); bar.setAttribute('aria-label', p.name + ' progress');
        pr.append(bar, el('span', 'pct', p.pct + '%'));
        if (grown.has(p.id)) { fill.style.transition = 'none'; fill.style.width = p.pct + '%'; } else { grown.add(p.id); requestAnimationFrame(() => { fill.style.width = p.pct + '%'; }); }
      }
      const meta = el('div', 'pt-meta');
      const se = shipEta(p.eta); if (se) { const e = el('span'); e.append(ic('rocket'), document.createTextNode(se)); meta.append(e); }
      const sEp = sessionStamp(p);
      if (p.updated || sEp) {
        const u = el('span', 'lst'); u.dataset.at = sEp ? new Date(sEp).toISOString() : (p.updatedAt || ''); u.dataset.live = (p.status === 'shipped' || p.status === 'paused') ? '' : '1';
        u.dataset.words = '1'; u.dataset.rk = 'project:' + p.id; u.dataset.base = (p.status === 'paused' ? 'Paused since ' : 'Updated ') + (sEp ? localStamp(sEp) : shortStamp(p.updatedAt, p.updated));
        u.append(ic(p.status === 'paused' ? 'pause' : 'clock'), el('span', 'lstx', u.dataset.base)); meta.append(u);
      }
      // Home tiles never show lane counts ("N lanes: x building, y done").
      if (meta.children.length) pr.append(meta); else if (!hasPct(p)) pr.remove();
      // A project tile shows the project and its decisions only. No lane or session lists,
      // no lane history; only a stopped lane that needs a person surfaces, as a needs-you line.
      const PF = window.OSRC_HUB_PROOF; if (PF) PF.tileLines(p, { el, ic }).filter((n) => n.classList.contains('stop')).forEach((n) => t.append(n));
      const topN = ds.filter(isTop).length;
      const rest = ds.filter((d) => !isTop(d)).sort((a, b) => cmpDec({ p, d: a }, { p, d: b }));
      if (topN) t.append(el('p', 'pt-top5', topN + (topN === 1 ? ' decision waiting, shown above' : ' decisions waiting, shown above')));
      if (rest.length) {
        const ul = el('ul', 'pt-decs');
        rest.slice(0, 2).forEach((d) => { const li = el('li'); const b = el('button', 'dbtn'); b.type = 'button'; b.id = 'ptd-' + (d.owner || p.id) + '-' + d.id; b.append(pri(d.weight), el('span', null, d.short || d.q)); b.title = d.q || ''; b.addEventListener('click', (e) => { e.stopPropagation(); go(p.id, (d.owner || p.id) + '-' + d.id); }); li.append(b); const dsi = decStaleInfo(p, d); if (dsi) li.append(el('span', 'dec-stale', dsi.text)); ul.append(li); });
        t.append(ul);
        if (rest.length > 2) { const m = el('button', 'pt-more', 'and ' + (rest.length - 2) + ' more'); m.type = 'button'; m.id = 'ptm-' + p.id; m.addEventListener('click', (e) => { e.stopPropagation(); go(p.id); }); t.append(m); }
      } else if (!topN) { const n = el('p', 'pt-none'); n.append(ic('circle-check'), document.createTextNode('Nothing waiting on you.')); t.append(n); }
      t.addEventListener('click', () => go(p.id));
      return t;
    }

    // ---- Finished lanes: a lane that ended stays listed under its project for a while. -------------
    function endedLanes(p) {
      const ls = (p.lanes || []).filter((l) => l.ended || ENDED.includes(l.status)); if (!ls.length) return null;
      const names = ls.map((l) => l.short || l.id), shown = names.slice(0, 3).join(', ');
      const f = el('p', 'pt-ended'); f.append(ic('circle-check'), el('span', null, 'Finished: ' + shown + (names.length > 3 ? ' and ' + (names.length - 3) + ' more' : '')));
      f.title = ls.map((l) => (l.short || l.id) + ' · ' + String(l.status || 'Done').toLowerCase()).join('\n');
      return f;
    }

    // ---- At a glance: what is running, what needs me, what is left on my plans. --------------------
    // The "things need you" tile lists the decisions themselves, each one a link to its card; the tile
    // body opens the most urgent one. Lane housekeeping (READY lanes nobody reviewed, a project with no
    // watcher) is the orchestrator's job, so it shows as one short "Claude's to-do" line per project,
    // never as a needs-you alarm per lane.
    const span = (m) => (m < 60 ? m + ' min' : m < 2880 ? Math.round(m / 60) + ' h' : Math.round(m / 1440) + ' days');
    function chores(running) {
      const out = [];
      running.forEach((p) => {
        const al = Array.isArray(p.alerts) ? p.alerts : [];
        const rev = al.filter((a) => a.kind === 'unreviewed').length, stuck = al.filter((a) => a.kind !== 'unreviewed' && !LOUD.includes(a.kind)).length;
        const bits = [];
        if (stuck) bits.push(stuck + (stuck === 1 ? ' stalled lane' : ' stalled lanes') + ' to unstick');
        if (rev) bits.push(rev + (rev === 1 ? ' finished lane' : ' finished lanes') + ' to review');
        if (p.watcher && p.watcher.missingMin != null) bits.push('no watcher for ' + span(p.watcher.missingMin));
        if (bits.length) out.push({ p, text: bits.join(', ') });
      });
      return out;
    }
    function needTile(li, need, all, askers, proofStops, running) {
      const go = ctx.go, decs = all.slice().sort(cmpDec);
      li.append(el('span', 'gv', String(need)), el('span', 'gl', need === 1 ? 'thing needs you' : 'things need you'));
      if (!need) li.append(el('span', 'gs', 'Nothing waiting'));
      const ul = el('div', 'gneed');
      decs.slice(0, 4).forEach(({ p, d }) => {
        const b = el('button', 'gnd'); b.type = 'button'; b.id = 'gn-' + p.id + '-' + d.id; b.title = d.q || '';
        b.append(pri(d.weight), el('span', 'gndt', d.short || d.q));
        b.addEventListener('click', (e) => { e.stopPropagation(); go(p.id, (d.owner || p.id) + '-' + d.id); });
        ul.append(b);
      });
      if (decs.length > 4) { ul.append(el('span', 'gs', 'and ' + (decs.length - 4) + ' more below')); }
      askers.forEach(({ p, n }) => {
        const b = el('button', 'gnd'); b.type = 'button'; b.append(el('span', 'gndt', n + (n === 1 ? ' lane is asking you' : ' lanes are asking you') + ' · ' + p.name));
        b.addEventListener('click', (e) => { e.stopPropagation(); go(p.id); }); ul.append(b);
      });
      if (proofStops) { ul.append(el('span', 'gs', proofStops + (proofStops === 1 ? ' lane stopped on proof' : ' lanes stopped on proof'))); }
      if (ul.children.length) li.append(ul);
      const ch = [];   // Claude's chores (no watcher etc.) never show on Home; the stop guard enforces them
      if (ch.length) {
        const cl = el('div', 'gchore'); cl.append(el('span', 'gchh', "Claude's to-do, not yours"));
        ch.forEach(({ p, text }) => { const b = el('button', 'gch'); b.type = 'button'; b.append(el('b', null, p.name), document.createTextNode(': ' + text)); b.addEventListener('click', (e) => { e.stopPropagation(); go(p.id); }); cl.append(b); });
        li.append(cl);
      }
      const first = decs[0] || null, ask0 = askers[0] || null;
      if (first || ask0) { li.classList.add('gclick'); li.addEventListener('click', () => (first ? go(first.p.id, (first.d.owner || first.p.id) + '-' + first.d.id) : go(ask0.p.id))); }
    }
    function glance(running, all) {
      const waiting = all.length;
      const items = [];
      items.push({ v: String(running.length), l: running.length === 1 ? 'project running' : 'projects running',
        s: running.length ? '' : 'Nothing started' });
      const askers = running.map((p) => ({ p, n: liveLanes(p).filter((l) => ['approval', 'question'].includes(laneState(l))).length })).filter((x) => x.n);
      const asks = askers.reduce((a, x) => a + x.n, 0);
      const proofStops = window.OSRC_HUB_PROOF ? window.OSRC_HUB_PROOF.needs(running) : 0;
      const need = waiting + proofStops;   // decisions only; a lane asking is its orchestrator's job
      items.push({ need, hot: need > 0, askers: [], proofStops });
      // Plans: the tightest real reading. No reading, no tile (never a placeholder number).
      const pr = planReadings(ctx.limits);
      if (pr.lim) items.push({ v: Math.round(pr.lim.n) + '%', l: 'left on ' + (pr.lim.l.name || pr.lim.l.id), plans: pr.lims, hot: pr.hot });
      const ul = el('ul', 'glance'); ul.setAttribute('aria-label', 'At a glance'); if (ul.style && ul.style.setProperty) ul.style.setProperty('--cols', String(items.length));
      items.forEach((x) => {
        const li = el('li', (x.hot ? 'hot' : '') + (x.plans ? ' gplans' : '') || null);
        if (x.plans) {
          li.append(el('span', 'gl', 'Left on your plans'));
          x.plans.forEach((q) => { const r = el('span', 'gp'); r.append(el('span', 'gpn', q.l.name || q.l.id), el('span', isFinite(q.n) ? 'gpv' : 'gpv gpt', isFinite(q.n) ? Math.round(q.n) + '%' : q.t));
            if (q.l.renews) r.append(el('span', 'gs gpr', 'Renews ' + q.l.renews)); li.append(r); });
        } else if (x.askers) { li.classList.add('gneedt'); needTile(li, x.need, all, x.askers, x.proofStops, running); }
        else { li.append(el('span', 'gv', x.v), el('span', 'gl', x.l)); if (x.s) li.append(el('span', 'gs', x.s)); }
        ul.append(li);
      });
      return ul;
    }

    // ---- Also running: other Claude Code sessions working now. Read-only, no actions. --------------
    const ALSO_ST = { working: 'Working', waiting: 'Waiting on you' };
    function alsoRunning() {
      const rows = ctx.also || []; if (!rows.length) return null;
      const sec = el('section'); sec.append(el('h2', null, 'Also running'));
      const ul = el('ul', 'also'); ul.setAttribute('aria-label', 'Other Claude Code sessions');
      rows.forEach((r) => {
        const li = el('li'); li.id = 'also-' + r.key;
        const st = ALSO_ST[r.state] || (r.idleMin >= 1 ? 'Idle ' + (r.idleMin >= 60 ? Math.floor(r.idleMin / 60) + ' h ' + (r.idleMin % 60) + ' min' : r.idleMin + ' min') : 'Idle, just now');
        // "<Project> · <title>": the project in bold, the session's own title after it.
        const nm = el('span', 'an'); const p0 = r.project && r.name.indexOf(r.project + ' · ') === 0 ? r.project : '';
        if (p0) nm.append(el('b', null, p0), document.createTextNode(r.name.slice(p0.length))); else nm.append(el('b', null, r.name));
        li.append(el('span', 'dot ' + (r.state === 'working' ? 'ok' : r.state === 'waiting' ? 'waiting' : '')), nm, el('span', 'am', r.model || ''), el('span', 'as ' + (r.state || ''), st));
        li.title = [r.name, r.model, st].filter(Boolean).join(' · ');
        ul.append(li);
      });
      sec.append(ul); return sec;
    }

    function renderHome() {
      const projects = ctx.projects, db = ctx.db, go = ctx.go;
      const main = $('main'); main.replaceChildren();   // no hide(): an open card re-anchors after the render (keepHover)
      const live = projects.filter((p) => p.status !== 'shipped');
      const running = live.filter((p) => p.liveLanes == null ? liveLanes(p).length > 0 : p.liveLanes > 0);
      const shipped = projects.filter((p) => p.status === 'shipped');
      const all = []; live.forEach((p) => openDecs(p).forEach((d) => all.push({ p, d })));
      const ph = el('header', 'ph home');
      const waitingOn = new Set(all.map((x) => x.p.id)).size;
      const err = ctx.pullErr, oldKey = /HTTP 40[13]/.test(err || '');   // a key from an older hub is not "hub down"
      const head = !projects.length ? (oldKey ? 'This tab is from an older Mission Control' : err ? 'Cannot reach the local hub' : db ? 'Nothing is running right now' : 'Sign in to see your projects')
        : all.length ? all.length + (all.length === 1 ? ' decision waits on you' : ' decisions wait on you') : running.length ? 'Nothing is waiting on you' : 'Nothing is running right now';
      const sub = !projects.length ? (oldKey ? 'Its key no longer opens the data. Press Reopen below, or run "outsourcerer mc".' : err ? 'Is hub serve running? (' + err + ')' : db ? 'This page fills in by itself the moment a Claude Code session hands work to Outsourcerer.' : 'Open this board on claude.ai while signed in.')
        : all.length ? 'Across ' + waitingOn + (waitingOn === 1 ? ' project.' : ' projects.') : running.length ? 'Everything is moving.' : live.length ? 'No lanes are working.' : 'Everything you started has shipped.';
      ph.append(el('h1', null, head), el('p', 'lede', sub));
      if (!projects.length && db && !err) {   // an empty page says how to start, never a blank
        const how = el('div', 'empty-how');
        const a = el('p', null, 'To start one, ask Claude Code to outsource a task, for example “outsource the test fixes to Codex”.');
        const b = el('p'); b.append(document.createTextNode('Or run it yourself: '), el('code', null, 'outsourcerer bg edit "fix the failing tests"'));
        how.append(a, b); ph.append(how);
      }
      main.append(ph);
      if (db && !err) main.append(glance(running, all));
      const top = all.filter((x) => isTop(x.d)).sort(cmpDec);
      if (top.length) {
        const sec = el('section', 'card toppri'); const h = el('h2'); h.id = 'tp-h'; h.append(ic('hand'), el('span', null, 'These are top-priority decisions for you right now.')); sec.setAttribute('aria-labelledby', 'tp-h');
        const ul = el('ul', 'tplist');
        top.forEach(({ p, d }) => {
          const dsi = decStaleInfo(p, d);
          const li = el('li', 'tprow' + (dsi ? ' stale' : '')); const q = el('div', 'tpq'); q.append(el('span', 'tpn', p.name), el('span', 'tpt', d.short || d.q));
          if (dsi) q.append(el('span', 'tp-stale', dsi.text));
          // Only the first Decide is filled; the rest are ghost buttons so the eye lands on one call to action.
          const b = el('button', 'go' + (ul.children.length ? ' ghost' : '')); b.type = 'button'; b.id = 'tp-' + p.id + '-' + d.id; b.append(document.createTextNode('Decide'), ic('arrow-right')); b.setAttribute('aria-label', 'Decide: ' + (d.short || d.q));
          b.addEventListener('click', () => go(p.id, (d.owner || p.id) + '-' + d.id));
          const chev = ic('chevron-right'); chev.setAttribute('class', 'chev');
          li.append(pri(d.weight), q, b, chev); ul.append(li);
          li.addEventListener('click', (e) => { if (window.innerWidth <= 520 && e.target !== b) go(p.id, (d.owner || p.id) + '-' + d.id); });
        });
        sec.append(h, ul); main.append(sec);
      }
      const active = live.filter((p) => !isQuiet(p));
      const quiet = live.filter((p) => isQuiet(p));
      const list = active.length ? active : (!live.length ? shipped : []);
      if (list.length) {
        const sec = el('section'); sec.append(el('h2', null, active.length ? 'Your projects' : 'Shipped'));
        const grid = el('div', 'ptiles' + (list.length === 1 ? ' one' : '')); list.forEach((p) => grid.append(ptile(p)));
        sec.append(grid); main.append(sec);
      }
      if (quiet.length) {
        const det = el('details', 'quiet-fold'); det.id = 'quiet-fold';
        det.append(el('summary', null, 'Quiet (' + quiet.length + ')'));
        const qgrid = el('div', 'ptiles' + (quiet.length === 1 ? ' one' : '')); quiet.forEach((p) => qgrid.append(ptile(p)));
        det.append(qgrid); main.append(det);
      }
      // No session lists on Home ("Also running" removed); projects and decisions only.
      if (live.length && shipped.length) main.append(el('p', 'foot', shipped.length + ' shipped, listed under Shipped in the sidebar.'));
      ctx.staleCheck(); paint();
    }

    return { renderHome, planReadings, refreshBtn, setShipped, utoast, doneBtn, sumLine, hasPct, laneList, localStamp, freshText, projFresh, etaAsOf, sessionStamp };
  };
})();
