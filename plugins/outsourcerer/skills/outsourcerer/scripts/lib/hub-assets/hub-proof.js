// hub-proof.js: verification stamps on Mission Control (0.17, lane S2). The export puts lane.proof
// ({stamp, method, ok, stopped, rounds, why, lines}) and project.unverifiedLanes / needsYouLanes on the
// doc (lib/proof.sh). This file only renders them; hub-home.js calls it.
(function () {
  'use strict';
  const stamp = (l) => (l && l.proof && l.proof.stamp) || '';
  const stopped = (p) => (p.lanes || []).filter((l) => l.proof && l.proof.stopped);

  // Lines for a project tile: each stopped lane (it needs a person) and the unverified count.
  function tileLines(p, h) {
    const out = [];
    stopped(p).forEach((l) => {
      const n = h.el('p', 'pt-proof stop');
      n.append(h.ic('hand'), h.el('span', null, (l.short || l.id) + ' stopped after ' + (l.proof.rounds || 3) + ' failed proof rounds. Needs you.'));
      n.title = [l.proof.why || ''].concat(l.proof.lines || []).filter(Boolean).join('\n');
      out.push(n);
      const last = (l.proof.lines || []).slice(-4);   // the last failing lines, on the card itself
      if (last.length) { const pre = h.el('pre', 'pt-proof-lines', last.join('\n')); out.push(pre); }
    });
    (p.lanes || []).filter((l) => l.reviewNeedsYou).forEach((l) => {
      const n = h.el('p', 'pt-proof stop');
      n.append(h.ic('hand'), h.el('span', null, (l.short || l.id) + ': review ' + l.reviewNeedsYou.item + ' has no readable verdict after one retry. Needs you.'));
      n.title = l.reviewNeedsYou.why || '';
      out.push(n);
    });
    const u = p.unverifiedLanes || 0;
    if (u > 0) { const n = h.el('p', 'pt-proof'); n.append(h.ic('eye'), h.el('span', null, u + (u === 1 ? ' lane' : ' lanes') + ' landed unverified')); out.push(n); }
    return out;
  }

  // Stopped lanes across projects, for the "things need you" tile.
  function needs(projects) { return (projects || []).reduce((a, p) => a + stopped(p).length + (p.lanes || []).filter((l) => l.reviewNeedsYou && !(l.proof && l.proof.stopped)).length, 0); }

  window.OSRC_HUB_PROOF = { stamp, tileLines, needs };
})();
