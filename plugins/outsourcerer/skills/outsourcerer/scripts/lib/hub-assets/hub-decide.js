/* Mission Control decision cards: the answer form and its drafts (MC-4), moved out of hub.html in MC-5 so the
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
      const c = el('div', 'card dec'); c.id = 'dec-' + d.id;
      c.append(tags(d), el('span', 'q', d.q));
      if (d.rec) c.append(el('span', null, d.rec));
      if (d.when) c.append(el('span', 'mono', 'Needed by ' + d.when));
      const a = el('div', 'ans'); const opts = el('div', 'opts');
      const key = p.id + '--' + d.id, f = forms[key] || (forms[key] = { choice: '', note: '', msg: '', err: false }); f.btns = [];
      (d.options || []).forEach((o, i) => {
        const b = el('button', 'opt', o); b.type = 'button'; b.id = 'opt-' + p.id + '-' + d.id + '-' + i; b.setAttribute('aria-pressed', String(o === f.choice));
        b.addEventListener('click', () => { f.choice = f.choice === o ? '' : o; f.btns.forEach((x) => x.setAttribute('aria-pressed', String(x.textContent === f.choice))); sync(); });
        f.btns.push(b); opts.appendChild(b);
      });
      const ta = document.createElement('textarea'); ta.id = 'note-' + p.id + '-' + d.id; ta.placeholder = 'Anything to add, or your own answer'; ta.setAttribute('aria-label', 'Note'); ta.setAttribute('dir', 'auto');
      ta.dataset.k = key; ta.value = f.note; if (f.h) ta.style.height = f.h; if (f.top) requestAnimationFrame(() => { ta.scrollTop = f.top; });
      const go2 = el('button', 'go'); go2.append(ic('send'), document.createTextNode('Send answer')); go2.type = 'button'; go2.id = 'send-' + p.id + '-' + d.id;
      const st = el('span', 'saved'); st.setAttribute('aria-live', 'polite');
      const sync = () => { go2.disabled = !db || (!f.choice && !ta.value.trim()); };
      const say = (m, err) => { f.msg = m; f.err = !!err; st.textContent = m; st.classList.toggle('err', !!err); };
      ta.addEventListener('input', () => { f.note = ta.value; sync(); }); sync(); say(f.msg, f.err);
      if (!db) st.textContent = 'Answering works when you are signed in on claude.ai.';
      go2.addEventListener('click', async () => {
        go2.disabled = true; say('Saving…'); saving++;   // renders hold while a send is in flight (MC-4)
        try {
          await db.doc('answers/' + p.id + '--' + d.id).set({ project: p.id, decision: d.id, question: d.q, choice: f.choice, note: ta.value.trim(), at: new Date().toISOString() });
          say('Saved. Your orchestrator reads it when it checks Mission Control.'); delete forms[key];
        } catch (e) { say('Not saved: ' + ((e && e.message) || 'try again'), true); sync(); } finally { saving--; ctx.flush(); }
      });
      a.append(opts, ta, go2, st); c.appendChild(a);
      return c;
    }

    return { decCard, capture, busy: () => saving > 0 };
  };
})();
