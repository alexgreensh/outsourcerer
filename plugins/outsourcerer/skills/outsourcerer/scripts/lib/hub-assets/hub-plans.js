/* Mission Control plans card helpers (0.16.3). Served from /assets/hub-plans.js; hub.html calls
   window.OSRC_HUB_PLANS.windows(row, el, ic) and falls back to its single "Renews" line when this file
   is missing. A plan whose source publishes several windows (Claude and Codex 5-hour + weekly,
   Antigravity's model groups) gets one line per window, each with its own renew time. */
(function () {
  const SHORT = { claude5h: '5 hours', claude7d: 'Week', codex5h: '5 hours', codexwk: 'Week' };
  const DAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'], MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const two = (n) => String(n).padStart(2, '0');
  // renew(epoch s) -> "today · 18:40" | "tomorrow · 09:10" | "in 4 days · Thu 19 Nov", viewer's local time; "" when past.
  function renew(t) {
    const ms = Number(t) > 1e11 ? Number(t) : Number(t) * 1000; if (!isFinite(ms) || ms <= Date.now()) return '';
    const d = new Date(ms), n = new Date(), day = (x) => Math.round(new Date(x.getFullYear(), x.getMonth(), x.getDate()) / 864e5);
    const k = day(d) - day(n), hm = two(d.getHours()) + ':' + two(d.getMinutes());
    return k === 0 ? 'today · ' + hm : k === 1 ? 'tomorrow · ' + hm : 'in ' + k + ' days · ' + DAY[d.getDay()] + ' ' + d.getDate() + ' ' + MON[d.getMonth()];
  }
  function list(l) {
    const w = l && l.windows && typeof l.windows === 'object' ? l.windows : {};
    return Object.keys(w).map((k) => Object.assign({ k }, w[k] || {}))
      .filter((x) => typeof x.left === 'number' || x.note);
  }
  function windows(l, el, ic) {
    const ws = list(l); if (ws.length < 2) return null;   // one window: the row's own "Renews" line says it all
    const box = el('span', 'lwins');
    ws.forEach((w) => {
      const line = el('span', 'lwin');
      line.append(el('span', 'lwl', w.label || SHORT[w.k] || w.k));
      if (typeof w.left === 'number') line.append(el('span', 'lwv', Math.round(w.left) + '% left'));
      else line.append(el('span', 'lwv lwn', /paused/i.test(w.note || '') ? 'Paused' : (w.note || '')));
      const when = w.renews || renew(w.renews_at);
      if (when && typeof w.left === 'number' && w.left < 100) { const rn = el('span', 'lwr'); if (ic) rn.append(ic('rotate-ccw')); rn.append(document.createTextNode((w.left <= 0 ? 'Back ' : 'Renews ') + when)); line.append(rn); }
      if (w.note && typeof w.left !== 'number') line.title = w.note;
      box.append(line);
    });
    return box;
  }
  function startChecks(button, refresh) {
    async function check() {
      if (button.disabled) return;
      button.disabled = true;
      if (button.dataset) button.dataset.state = 'checking';   // renderLimits reads this: the stamp yields to the one 'Checking…' state
      button.textContent = 'Checking…';
      try {
        await refresh();
        button.textContent = 'Check again';
      } catch {
        button.textContent = 'Retry check';
      } finally {
        button.disabled = false;
        if (button.dataset) button.dataset.state = 'idle';
      }
    }
    button.hidden = false;
    button.onclick = check;
    check();
    const timer = setInterval(check, 300000);
    return () => clearInterval(timer);
  }
  window.OSRC_HUB_PLANS = { windows, list, renew, startChecks };
})();
