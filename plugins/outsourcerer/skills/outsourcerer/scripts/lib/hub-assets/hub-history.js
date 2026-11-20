/* Mission Control History. Served by `hub serve` from /assets/hub-history.js (script-src 'self');
   lives outside hub.html so the page stays under the 1,000-line rule. Reads p.history from the export
   (lib/hub-history.sh): lanes with outcomes, releases, merged/closed PRs, closed issues, newest first.
   Text only goes through el() (textContent); links are GitHub https URLs the export already filtered. */
(function () {
  const OUT = { running: 'Running', finished: 'Finished', stopped: 'Stopped', failed: 'Failed', merged: 'Merged', closed: 'Closed', 'not planned': 'Not planned' };
  const ICON = { lane: 'circle-check', release: 'rocket', pr: 'git-merge', issue: 'check' };   // names from hub.html ICONS
  const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const when = (s) => { const d = new Date(s * 1000), p = (n) => String(n).padStart(2, '0'); return d.getDate() + ' ' + MON[d.getMonth()] + ', ' + p(d.getHours()) + ':' + p(d.getMinutes()); };
  const n = (k, one, many) => k + ' ' + (k === 1 ? one : many);
  const lanesOf = (p) => ((p.history && p.history.items) || []).filter((i) => i.kind === 'lane');

  // "3 releases · 6 PRs merged · 4 issues closed this week" (Home card); "" when the week was quiet.
  function summary(p) {
    const w = p.history && p.history.week; if (!w) return '';
    const parts = [w.releases ? n(w.releases, 'release', 'releases') : '', w.prsMerged ? n(w.prsMerged, 'PR merged', 'PRs merged') : '',
      w.issuesClosed ? n(w.issuesClosed, 'issue closed', 'issues closed') : '', w.lanesFinished ? n(w.lanesFinished, 'lane finished', 'lanes finished') : ''].filter(Boolean);
    return parts.length ? parts.join(' · ') + ' this week' : '';
  }

  function laneRow(h, l) {
    const li = h.el('li', 'hx-lane hx-' + (l.outcome || 'stopped'));
    li.append(h.ic(l.outcome === 'finished' ? 'circle-check' : l.outcome === 'failed' ? 'octagon-x' : l.outcome === 'running' ? 'hammer' : 'pause'),
      h.el('span', 'hx-t', l.title || 'Lane'), h.el('span', 'hx-m', [l.model, OUT[l.outcome] || ''].filter(Boolean).join(' · ')),
      h.el('span', 'hx-d mono', l.at ? when(l.at) : ''));
    li.title = [l.title, l.model, l.start ? 'started ' + when(l.start) : '', l.end ? 'ended ' + when(l.end) : '', OUT[l.outcome]].filter(Boolean).join(' · ');
    return li;
  }

  // "Finished (N)": a <details> fold of the lanes that ended, green check per finished lane. Open on the project
  // page, collapsed on Home cards.
  function finishedFold(h, p, open) {
    const done = lanesOf(p).filter((l) => l.outcome !== 'running'); if (!done.length) return null;
    const d = h.el('details', 'hx-fold'); if (open) d.open = true;
    d.append(h.el('summary', null, 'Finished (' + done.length + ')'));
    const ul = h.el('ul', 'hx-list'); done.forEach((l) => ul.append(laneRow(h, l))); d.append(ul);
    return d;
  }

  function itemRow(h, i) {
    if (i.kind === 'lane') return laneRow(h, i);
    const li = h.el('li', 'hx-' + i.kind + (i.outcome ? ' hx-' + i.outcome.replace(/\s/g, '-') : ''));
    const label = i.kind === 'release' ? (i.title || i.tag) : (i.kind === 'pr' ? 'PR #' : 'Issue #') + i.number + ' ' + (i.title || '');
    let t; if (i.url) { t = h.el('a', 'hx-t', label); t.href = i.url; t.target = '_blank'; t.rel = 'noopener noreferrer'; } else t = h.el('span', 'hx-t', label);
    const what = i.kind === 'release' ? (i.local ? 'Tag' : 'Release') : OUT[i.outcome] || '';
    li.append(h.ic(ICON[i.kind] || 'check'), t, h.el('span', 'hx-m', what), h.el('span', 'hx-d mono', i.at ? when(i.at) : ''));
    return li;
  }

  // The project page: "Lanes" (running first, then the Finished fold, open) and "History" (everything, newest first).
  function section(h, p) {
    const hs = p.history; if (!hs) return null;
    const wrap = h.el('div', 'hx');
    const lanes = lanesOf(p), live = lanes.filter((l) => l.outcome === 'running');
    if (lanes.length) {
      const s = h.el('section'); s.append(h.el('h2', null, 'Every lane (' + lanes.length + ')'));
      if (live.length) { const ul = h.el('ul', 'hx-list'); live.forEach((l) => ul.append(laneRow(h, l))); s.append(ul); }
      const f = finishedFold(h, p, true); if (f) s.append(f);
      wrap.append(s);
    }
    const s2 = h.el('section'); s2.append(h.el('h2', null, 'History'));
    const sm = hs.summary || {};
    s2.append(h.el('p', 'sub', [n(sm.releases || 0, 'release', 'releases'), n(sm.prsMerged || 0, 'PR merged', 'PRs merged'),
      sm.prsClosed ? n(sm.prsClosed, 'PR closed unmerged', 'PRs closed unmerged') : '', n(sm.issuesClosed || 0, 'issue closed', 'issues closed'),
      n(sm.lanes || 0, 'lane', 'lanes')].filter(Boolean).join(' · ') + (hs.repo ? ' in ' + hs.repo : '') + '.'));
    if (hs.github === 'unreachable') s2.append(h.el('p', 'hx-note', 'GitHub not reachable, showing local tags only.'));
    const ul = h.el('ul', 'hx-list hx-all'); (hs.items || []).forEach((i) => ul.append(itemRow(h, i)));
    if ((hs.items || []).length) s2.append(ul); else s2.append(h.el('p', 'hx-note', 'Nothing recorded yet.'));
    wrap.append(s2);
    return wrap;
  }

  window.OSRC_HUB_HISTORY = { summary, finishedFold, section };
})();
