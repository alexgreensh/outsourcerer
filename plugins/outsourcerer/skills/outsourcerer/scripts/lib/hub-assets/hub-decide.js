/* Mission Control decision cards: the answer form and its drafts, moved out of hub.html so the
   page stays under the 1,000-line rule. Served by `hub serve` from /assets/hub-decide.js (script-src 'self').
   hub.html calls window.OSRC_HUB_DECIDE(ctx) and gets back decCard(), busy() and capture().
   Drafts live in `forms`, keyed <project>--<decision> (choice, note, status line, textarea height + scroll), and
   outlive every re-render: polls, snapshots and trips to Home never wipe a half-typed answer. */
(function () {
  window.OSRC_HUB_DECIDE = function (ctx) {
    const { el, ic, tags } = ctx;
    const forms = {};
    let saving = 0;

    // Before main is rebuilt: keep each textarea's resized height and scroll position.
    function capture(main) {
      main.querySelectorAll('textarea[data-k]').forEach((t) => { const f = forms[t.dataset.k]; if (f) { f.h = t.style.height; f.top = t.scrollTop; } });
    }

    function decCard(p, d) {
      const db = ctx.db;
      // Ids carry the owning session: two sessions' D1 on one merged card stay distinct (focus, deep links).
      const o = (d.owner || p.id) + '-' + d.id, c = el('div', 'card dec'); c.id = 'dec-' + o;
      c.dataset.wait = 'd:' + (d.owner || p.id) + '--' + d.id; c.tabIndex = -1;   // n / p / 1-9 / Enter (hub-attn.js)
      c.append(tags(d), el('span', 'q', d.q));
      // A card stands on its own: what this is about, the orchestrator's pick, how long it waits.
      if (d.why) c.append(el('p', 'dwhy', d.why));
      if (d.rec) { const r = el('p', 'drec'); r.append(el('b', null, 'My pick: '), document.createTextNode(d.rec)); c.append(r); }
      if (!d.why && !d.rec && !(d.options || []).length) c.append(el('p', 'dwhy', 'This question came without background. Ask ' + (p.name || 'that session') + ' what it needs, or answer below.'));
      const asked = Date.parse(d.askedAt || ''), mins = isNaN(asked) ? -1 : Math.round((Date.now() - asked) / 60000);
      const meta = [d.when ? 'Needed by ' + d.when : '', mins >= 0 ? 'Asked ' + (mins < 60 ? mins + ' min' : mins < 2880 ? Math.round(mins / 60) + ' h' : Math.round(mins / 1440) + ' days') + ' ago' : ''].filter(Boolean).join(' · ');
      if (meta) c.append(el('span', 'mono', meta));
      const dsi = window.OSRC_HUB_CLEAN && window.OSRC_HUB_CLEAN.decStale ? window.OSRC_HUB_CLEAN.decStale(p, d) : null;
      if (dsi) { c.classList.add('stale'); c.append(el('p', 'dec-stale', dsi.text)); }
      const a = el('div', 'ans'); const opts = el('div', 'opts');
      const key = (d.owner || p.id) + '--' + d.id, f = forms[key] || (forms[key] = { choice: '', note: '', msg: '', err: false }); f.btns = [];
      (d.options || []).forEach((opt, i) => {
        const b = el('button', 'opt', opt); b.type = 'button'; b.id = 'opt-' + o + '-' + i; b.setAttribute('aria-pressed', String(opt === f.choice));
        b.addEventListener('click', () => { f.choice = f.choice === opt ? '' : opt; f.btns.forEach((x) => x.setAttribute('aria-pressed', String(x.textContent === f.choice))); sync(); });
        f.btns.push(b); opts.appendChild(b);
      });
      const ta = document.createElement('textarea'); ta.id = 'note-' + o; ta.placeholder = 'Anything to add, or your own answer'; ta.setAttribute('aria-label', 'Note'); ta.setAttribute('dir', 'auto');
      ta.dataset.k = key; ta.value = f.note; if (f.h) ta.style.height = f.h; if (f.top) requestAnimationFrame(() => { ta.scrollTop = f.top; });
      const go2 = el('button', 'go'); go2.append(ic('send'), document.createTextNode('Send answer')); go2.type = 'button'; go2.id = 'send-' + o;
      const st = el('span', 'saved'); st.setAttribute('aria-live', 'polite');
      const sync = () => { go2.disabled = !db || (!f.choice && !ta.value.trim()); };
      const say = (m, err) => { f.msg = m; f.err = !!err; st.textContent = m; st.classList.toggle('err', !!err); };
      ta.addEventListener('input', () => { f.note = ta.value; sync(); }); sync(); say(f.msg, f.err);
      if (!db) st.textContent = 'Answering works when you are signed in on claude.ai.';
      go2.addEventListener('click', async () => {
        go2.disabled = true; say('Saving…'); saving++;   // renders hold while a send is in flight
        try {
          await db.doc('answers/' + (d.owner || p.id) + '--' + d.id).set({ project: d.owner || p.id, decision: d.id, question: d.q, choice: f.choice, note: ta.value.trim(), at: new Date().toISOString() });
          say('Saved. Your orchestrator reads it when it checks Mission Control.'); delete forms[key];
        } catch (e) { say(e && e.timeout ? 'Not sent, try again' : 'Not saved: ' + ((e && e.message) || 'try again'), true); sync(); }
        finally { saving--; ctx.flush(!c.isConnected); }   // navigated away mid-send: re-render so the live card shows the outcome
      });
      a.append(opts, ta, go2, st); c.appendChild(a);
      return c;
    }

    return { decCard, capture, busy: () => saving > 0 };
  };
})();
