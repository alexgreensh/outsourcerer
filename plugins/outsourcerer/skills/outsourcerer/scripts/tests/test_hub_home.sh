#!/usr/bin/env bash
# test_hub_home.sh -- MC-3 Mission Control Home port:
#   * POST /api/projects/<id>/status (Mark done / Move back): token, origin, strict id, known project only
#   * hub export merges the user's override LAST (shippedBy "user" survives any card write)
#   * Move back clears only a card "shipped" older than the click
#   * page contract: Home is the default view, top bar text, Home entry, logo -> Home, icons, CSP/asset
#   * Refresh button appears only on a stale stamp (hub-home.js refreshBtn run in node, no browser)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
LIB="$HERE/../lib"
PAGE="$LIB/hub.html"
JS="$LIB/hub-assets/hub-home.js"
DEC="$LIB/hub-assets/hub-decide.js"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hub-home-test.XXXXXX")"   # never beside the suites (MC-5 #8); trap removes it
SRV=""
cleanup() { [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }; rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc" XDG_CONFIG_HOME="$TMP/xdg"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1 OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
mkdir -p "$HOME" "$OSRC_HOME/hub/projects" "$OSRC_HOME/hub/decisions" "$XDG_CONFIG_HOME"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
run() { OSRC_HOME="$OSRC_HOME" bash "$SRC" "$@"; }
old_touch() { touch -t "$(date -u -v-"$1" '+%Y%m%d%H%M.%S' 2>/dev/null || date -u -d "${1%H} hours ago" '+%Y%m%d%H%M.%S')" "$2"; }
st_of() { run hub export 2>/dev/null | jq -c --arg id "$1" '.projects[] | select(.id==$id) | {status, shippedBy, prevStatus}'; }

echo "=== page contract (Home port) ==="
grep -q '<script src="assets/hub-home.js"></script>' "$PAGE" && grep -q '<script src="assets/hub-decide.js"></script>' "$PAGE" && ok "page loads assets/hub-home.js + hub-decide.js" || bad "an asset script is not loaded by the page"
grep -q 'These are top-priority decisions for you right now.' "$JS" && ok "top bar text is exact" || bad "top bar text missing/changed"
grep -q "decisions wait on you" "$JS" && grep -q "'Across ' + waitingOn" "$JS" && ok "headline N decisions wait on you + Across M projects" || bad "Home headline missing"
grep -q 'id="homebtn"' "$PAGE" && grep -q 'id="hcount"' "$PAGE" && ok "Home entry + count badge in the rail" || bad "Home entry missing"
grep -q '<a class="brand" href="#home" id="brand"' "$PAGE" && ok "logo goes Home" || bad "logo still leaves the page"
grep -q 'class="star" href="https://github.com/alexgreensh/outsourcerer"' "$PAGE" && ok "GitHub stays on the Star button" || bad "Star button lost GitHub"
grep -q "if (H) return null;" "$PAGE" && ok "pickStart: no hash -> Home (null)" || bad "Home is not the default view"
grep -q "(!h || h === 'home') && current) goHome()" "$PAGE" && ok "#home / empty hash routes to Home" || bad "hash routing to Home missing"
grep -q '\[hidden\] { display: none !important; }' "$PAGE" && ok "[hidden] beats display rules" || bad "[hidden] rule missing"
grep -q "closeT = setTimeout(() => { if (!pinned) hide(); }, 250)" "$PAGE" && ok "hover card 250 ms close delay" || bad "hover close delay missing"
grep -q "pointer-events: none" "$PAGE" && bad "hover card still ignores the pointer" || ok "hover card accepts the pointer"
grep -q "if (pinned && owner && owner.isConnected) place(owner)" "$PAGE" && ok "pinned card survives scroll" || bad "pinned card closes on scroll"
grep -q "max-height: calc(100vh - 32px); overflow-y: auto" "$PAGE" && ok "hover card max-height scroll" || bad "hover card max-height missing"
grep -q "target.closest('.prline')" "$PAGE" && ok "rail cards anchor past the row" || bad "rail card anchor missing"
grep -q "const rf = refs(l.repo || p.repo, l.issues); if (rf) h.append(rf)" "$PAGE" && ok "lane hover: every issue its own link" || bad "lane hover refs missing"
grep -q "Mark done, move to Shipped" "$JS" && grep -q "Move back to running" "$JS" && grep -q "H.doneBtn(p, null, hide)" "$PAGE" && ok "Mark done / Move back in the rail card" || bad "Mark done missing"
# MC-7 (Alex approved all five proposals)
grep -q "H.doneBtn(p, 'hdone-' + p.id)" "$PAGE" && grep -q "meta.append(k)" "$PAGE" && ok "MC-7 #1: Mark done also in the project page header (a button, in the tab order)" || bad "MC-7 #1: header Mark done missing"
grep -q "@media (hover: none) { .ph .hcact { min-height: 44px; } }" "$PAGE" && ok "MC-7 #1: header button is a 44px touch target" || bad "MC-7 #1: header button touch size missing"
grep -q ".app:has(.ph.home) .main > .ph.home { order: 1;" "$PAGE" && grep -q ".app:has(.ph.home) .main > .toppri { order: 1;" "$PAGE" && ok "MC-7 #2: phone Home puts the headline and top-priority bar above the rail list" || bad "MC-7 #2: phone Home order missing"
grep -q "min-width: 1200px) { .pt-prog" "$PAGE" && bad "MC-7 #3: the tile stamp still shares the bar row at 1200px+" || { grep -q ".pt-meta { display: flex; flex-direction: column;" "$PAGE" && ok "MC-7 #3: tile stamp on its own row at every width" || bad "MC-7 #3: pt-meta is not a column"; }
grep -q ".tprow { display: grid; grid-template-columns: 4.25rem minmax(0, 1fr) auto;" "$PAGE" && ok "MC-7 #4: fixed pill column in the top-priority rows" || bad "MC-7 #4: pill column not fixed"
grep -q "row.append(stPill(p)" "$PAGE" && grep -q "top.append(nb, stPill(p))" "$JS" && grep -q "' st-wait'" "$PAGE" && ok "MC-7 #5: hover card and tile share one status pill" || bad "MC-7 #5: hover pill differs from the tile"
grep -q "}, 6000);" "$JS" && grep -q "'Undo'" "$JS" && ok "Undo toast, 6 s" || bad "Undo toast missing"
miss=""; for i in layout-grid hand arrow-right circle-check chevron-right rotate-ccw refresh-cw clock pause rocket check; do
  grep -q "^    '$i': '<" "$PAGE" || miss="$miss $i"
done; [ -z "$miss" ] && ok "every icon Home uses is in the inline ICONS map" || bad "icons missing from ICONS:$miss"
grep -qE '\b(alert|confirm|prompt) *\(' "$JS" && bad "dialog call in hub-home.js" || ok "no alert/confirm/prompt in hub-home.js"
grep -qi 'font-style: *italic\|<em>\|<i>[^<]' "$PAGE" && bad "italics in page" || ok "no italics"
grep -q 'border-left: *[0-9.]*px solid var(--hi)' "$PAGE" && bad "border-left accent stripe" || ok "no border-left accent stripes"
[ "$(wc -l < "$PAGE")" -le 1000 ] && [ "$(wc -l < "$JS")" -le 1000 ] && [ "$(wc -l < "$DEC")" -le 1000 ] && [ "$(wc -l < "$LIB/hub_server.py")" -le 1000 ] && [ "$(wc -l < "$LIB/hub.sh")" -le 1000 ] \
  && ok "hub.html/hub-home.js/hub_server.py/hub.sh each <= 1000 lines" || bad "a hub file passed 1000 lines"

echo "=== MC-4: drafts survive re-renders (page contract) ==="
grep -q "const key = p.id + '--' + d.id, f = forms\[key\] || (forms\[key\] =" "$DEC" && ok "decision draft keyed <project>--<decision> in forms" || bad "draft store missing"
grep -q "forms = {}" "$PAGE" "$JS" && bad "renderMain still wipes the drafts" || ok "renderMain no longer wipes the drafts"
grep -q "ta.value = f.note" "$DEC" && grep -q "String(o === f.choice)" "$DEC" && ok "text + chosen option restored on render" || bad "draft not restored"
grep -q "n.focus({ preventScroll: true })" "$PAGE" && grep -q "setSelectionRange(keep.s, keep.e" "$PAGE" && ok "focus + caret restored after render" || bad "focus/caret restore missing"
grep -q "if (composing || (D && D.busy())) { pending = true; return; }" "$PAGE" && grep -q "compositionend" "$PAGE" && ok "render held during IME composition and in-flight send" || bad "composition/send hold missing"
grep -q "if (s === sigP && !firstPull && !pullErr) return" "$PAGE" && grep -q "if (s === sigL) return" "$PAGE" && grep -q "k === 'exported_at'" "$PAGE" && ok "identical polls re-render nothing (projects, answers, limits)" || bad "identical-poll skip missing"
grep -q "function keepHover" "$PAGE" && grep -q "target._hb = build" "$PAGE" && ok "an open hover card re-anchors across re-renders (MC-5 #4)" || bad "hover re-anchor missing"
grep -q "grown.has(p.id)" "$JS" && grep -q "grown.has(p.id)" "$PAGE" && ok "bars animate once, not on every re-render (MC-5 #4)" || bad "bars re-grow on every render"
grep -q "new AbortController(), t = setTimeout(() => ac.abort(), 15000)" "$PAGE" && grep -q "'Not sent, try again'" "$DEC" \
  && ok "MC-6 #2: api() aborts after 15 s and the card says Not sent, try again" || bad "api timeout missing"
grep -q "renderRail(); pollRender();" "$PAGE" && ! grep -q "^    if (composing || (D && D.busy())) { pending = true; return; }" "$PAGE" \
  && ok "MC-6 #2: only poll-driven renders wait for a send; navigation never does" || bad "renderMain still holds navigation"
grep -q "document.addEventListener('focusout', (e) => { if (composing && e.target === compEl) { composing = false; flush(); } })" "$PAGE" \
  && grep -q "if (composing && compEl !== document.activeElement) composing = false;" "$PAGE" \
  && ok "MC-6 #3: losing the composing field clears the hold" || bad "composition flag can stick"
grep -q "resetForms" "$PAGE" "$JS" "$DEC" && bad "Home still resets drafts" || ok "going Home keeps drafts"

echo "=== refreshBtn: only on a stale stamp (node, no browser) ==="
if command -v node >/dev/null 2>&1; then
  rb="$(node - "$JS" <<'EOF' 2>&1
const fs = require('fs'), vm = require('vm');
function mk(tag) { const e = { tag, children: [], dataset: {}, className: '', disabled: false, isConnected: true,
  append(...k) { this.children.push(...k); }, appendChild(k) { this.children.push(k); return k; }, setAttribute() {}, classList: { contains: () => false }, replaceChildren(...k) { this.children = k; },
  addEventListener() {}, remove() { this.parent && (this.parent.children = this.parent.children.filter((x) => x !== this)); },
  querySelector(sel) { return this.children.find((c) => sel === '.' + c.className) || null; } };
  const ap = e.append.bind(e); e.append = (...k) => { k.forEach((x) => { if (x && typeof x === 'object') x.parent = e; }); ap(...k); }; return e; }
let box = null;
const win = {}; vm.runInNewContext(fs.readFileSync(process.argv[2], 'utf8'), { window: win, document: { createTextNode: (t) => ({ t }), body: { appendChild: (b) => { box = b; } } }, setTimeout, clearTimeout, requestAnimationFrame: () => {} });
const el = (tag, cls) => { const e = mk(tag); if (cls) e.className = cls; return e; };
const ctx = { $: (id) => (id === 'utoast' ? box : null), el, ic: () => mk('i'), pri: () => mk('span'), paint() {}, openDecs: () => [], byWeight: () => 0, STATUS_TXT: {},
  db: {}, canWrite: null, mode: 'local' };
const H = win.OSRC_HUB_HOME(ctx);
const st = el('span', 'lst'); st.dataset.rk = 'project:x';
H.refreshBtn(st, false); console.log('fresh=' + (st.querySelector('.rfr') ? 1 : 0));
H.refreshBtn(st, true);  console.log('stale=' + (st.querySelector('.rfr') ? 1 : 0));
H.refreshBtn(st, false); console.log('fresh-again=' + (st.querySelector('.rfr') ? 1 : 0));
ctx.canWrite = false; H.refreshBtn(st, true); console.log('viewer=' + (st.querySelector('.rfr') ? 1 : 0));
H.utoast('Moved X to Shipped', () => {}); H.utoast('Read again just now.');
console.log('undo-kept=' + (box.children.some((c) => c.children && c.children.length === 0 && c.tag === 'button') ? 1 : 0));
setTimeout(() => process.exit(0), 0);
EOF
)"
  grep -q 'fresh=0' <<<"$rb" && grep -q 'stale=1' <<<"$rb" && grep -q 'fresh-again=0' <<<"$rb" && grep -q 'viewer=0' <<<"$rb" \
    && ok "Refresh only on stale stamps, removed when fresh, hidden from viewers" || bad "refreshBtn wrong: $rb"
  grep -q 'undo-kept=1' <<<"$rb" && ok "a late info toast never replaces a live Undo" || bad "Undo toast replaced: $rb"
else echo "SKIP: node not installed (refreshBtn unit)"; fi

echo "=== export merges the Mark done override ==="
echo '{"name":"Alpha","status":"review","pct":80,"order":1}' > "$OSRC_HOME/hub/projects/alpha.json"
echo '{"name":"Beta","status":"shipped","pct":100,"order":2}' > "$OSRC_HOME/hub/projects/beta.json"
mkdir -p "$OSRC_HOME/hub/status"
echo '{"status":"shipped","shippedAt":"2026-11-14T10:00:00Z","shippedBy":"user","prevStatus":"review"}' > "$OSRC_HOME/hub/status/alpha.json"
[ "$(st_of alpha)" = '{"status":"shipped","shippedBy":"user","prevStatus":"review"}' ] && ok "override merged: shipped by user" || bad "override not merged: $(st_of alpha)"
echo '{"name":"Alpha","status":"building","pct":90,"order":1}' > "$OSRC_HOME/hub/projects/alpha.json"   # orchestrator rewrites the card
[ "$(st_of alpha | jq -r '.status+"/"+.shippedBy')" = "shipped/user" ] && ok "shippedBy user survives a card rewrite + re-export" || bad "card write undid the user's ship: $(st_of alpha)"
ln -s "$OSRC_HOME/hub/status/alpha.json" "$OSRC_HOME/hub/status/beta.json"
[ "$(st_of beta | jq -r .status)" = "shipped" ] && [ "$(st_of beta | jq -r .shippedBy)" = "null" ] && ok "symlinked override ignored" || bad "symlinked override merged: $(st_of beta)"
rm -f "$OSRC_HOME/hub/status/beta.json"
echo '{"restoredBy":"user","restoredAt":"x","prevStatus":"building","cardStatus":"shipped","cardShippedAt":null}' > "$OSRC_HOME/hub/status/beta.json"
[ "$(st_of beta | jq -r .status)" = "building" ] && ok "Move back clears the card's shipped" || bad "restore ignored: $(st_of beta)"
sleep 1; echo '{"name":"Beta","status":"shipped","pct":100,"order":2}' > "$OSRC_HOME/hub/projects/beta.json"   # heartbeat rewrites the same card
[ "$(st_of beta | jq -r .status)" = "building" ] && ok "Move back survives a rewrite of the same card (MC-5 #2)" || bad "card rewrite undid Move back: $(st_of beta)"
echo '{"name":"Beta","status":"shipped","shippedAt":"2026-11-20T09:00:00Z","pct":100,"order":2}' > "$OSRC_HOME/hub/projects/beta.json"
[ "$(st_of beta | jq -r .status)" = "shipped" ] && ok "a card that ships again (new shippedAt) wins over Move back" || bad "restore pinned forever: $(st_of beta)"
mkdir -p "$TMP/elsewhere" && echo '{"status":"shipped","shippedBy":"user"}' > "$TMP/elsewhere/alpha.json"
mv "$OSRC_HOME/hub/status" "$TMP/status.real" && ln -s "$TMP/elsewhere" "$OSRC_HOME/hub/status"
[ "$(st_of alpha | jq -r .shippedBy)" = "null" ] && ok "export never reads overrides through a symlinked status folder" || bad "export followed a symlinked status folder"
rm "$OSRC_HOME/hub/status" && mv "$TMP/status.real" "$OSRC_HOME/hub/status"

echo "=== write_status slug guard alone (poisoned export) ==="
# The project-exists check masks the slug regex for real exports (every exported id is a
# valid slug), so prove the regex on its own: an export that lists "../evil" is still refused.
sg="$(cd "$LIB" && OSRC_T="$TMP/sg" PAGE="$PAGE" python3 -I -c '
import os, sys, time; sys.path.insert(0, os.getcwd()); import hub_server as h
t = os.environ["OSRC_T"]; os.makedirs(t)
hub = h.Hub(t, "/bin/false", os.environ["PAGE"], "x")
for bad in ("../evil", ".hidden", "a/b", "alpha\n"):
    hub.cache = {"projects": [{"id": bad, "status": "building"}]}; hub.cache_ts = time.time()
    print(bad, hub.write_status(bad, {"status": "shipped"})[0])
print("escaped" if os.path.exists(os.path.join(t, "hub", "evil.json")) else "contained")
sd = os.path.join(t, "hub", "status")
print("nl-file" if os.path.isdir(sd) and any("\n" in n for n in os.listdir(sd)) else "no-nl-file")
print("answer-nl", hub.write_answer({"id": "a--b\n", "choice": "x"})[1])
# MC-5 #6: the override is written even when the re-export fails -> 200 + export_error, not "not saved".
hub.cache = {"projects": [{"id": "ok1", "status": "review"}]}; hub.cache_ts = time.time()
code, body = hub.write_status("ok1", {"status": "shipped"})
print("exportfail", code, bool(body.get("export_error")), os.path.isfile(os.path.join(t, "hub", "status", "ok1.json")))
' 2>&1)"
grep -q '^\.\./evil 400$' <<<"$sg" && grep -q '^\.hidden 400$' <<<"$sg" && grep -q '^a/b 400$' <<<"$sg" && grep -q contained <<<"$sg" \
  && ok "slug regex alone refuses traversal ids even when the export lists them" || bad "slug guard: $sg"
grep -q '^alpha$' <<<"$sg" && grep -q '^ 400$' <<<"$sg" && grep -q '^no-nl-file$' <<<"$sg" \
  && ok "slug with a trailing newline refused, no file (MC-5 #5)" || bad "trailing-newline slug: $sg"
grep -q '^answer-nl bad answer id$' <<<"$sg" && ok "answer id with a trailing newline refused (MC-5 #5)" || bad "trailing-newline answer id: $sg"
grep -q '^exportfail 200 True True$' <<<"$sg" && ok "failed re-export: 200 + export_error, override kept (MC-5 #6)" || bad "export failure reply: $sg"

echo "=== symlink-safe writes (MC-5 #3) ==="
sy="$(cd "$LIB" && OSRC_T="$TMP/sy" PAGE="$PAGE" python3 -I -c '
import os, sys, time, stat; sys.path.insert(0, os.getcwd()); import hub_server as h
t = os.environ["OSRC_T"]; os.makedirs(os.path.join(t, "hub", "status")); os.makedirs(os.path.join(t, "victim"))
victim = os.path.join(t, "victim", "keep.txt"); open(victim, "w").write("original")
hub = h.Hub(t, "/bin/false", os.environ["PAGE"], "x")
hub.cache = {"projects": [{"id": "alpha", "status": "review"}]}; hub.cache_ts = time.time()
os.symlink(victim, os.path.join(t, "hub", "status", "alpha.json.tmp"))      # the old fixed temp name
c1, _ = hub.write_status("alpha", {"status": "shipped"})
f = os.path.join(t, "hub", "status", "alpha.json")
print("tmp", c1, open(victim).read(), os.path.islink(f), oct(os.stat(f).st_mode & 0o777), oct(os.stat(os.path.dirname(f)).st_mode & 0o777))
os.rename(os.path.join(t, "hub", "status"), os.path.join(t, "status.real")); os.symlink(os.path.join(t, "victim"), os.path.join(t, "hub", "status"))
c2, b2 = hub.write_status("alpha", {"status": "restore"})
print("dir", c2, sorted(os.listdir(os.path.join(t, "victim"))))
os.makedirs(os.path.join(t, "victim2")); os.rename(os.path.join(t, "hub", "answers"), os.path.join(t, "answers.real")); os.symlink(os.path.join(t, "victim2"), os.path.join(t, "hub", "answers"))
print("ans", hub.write_answer({"id": "a--b", "choice": "x"})[1] is not None, sorted(os.listdir(os.path.join(t, "victim2"))))
' 2>&1)"
grep -q "^tmp 200 original False 0o600 0o700$" <<<"$sy" && ok "planted temp-name symlink: target untouched, override written 600 in a 700 folder" || bad "temp symlink: $sy"
grep -q "^dir 409 \['keep.txt'\]$" <<<"$sy" && ok "symlinked status folder: 409, nothing written outside" || bad "status folder symlink: $sy"
grep -q "^ans True \[\]$" <<<"$sy" && ok "symlinked answers folder: refused, nothing written outside" || bad "answers folder symlink: $sy"

echo "=== POST /api/projects/<id>/status ==="
command -v curl >/dev/null 2>&1 || { echo "SKIP: curl"; echo "RESULTS: $pass pass $fail fail"; [ "$fail" -eq 0 ]; exit $?; }
rm -f "$OSRC_HOME/hub/status/"*.json
echo '{"name":"Alpha","status":"review","pct":80,"order":1}' > "$OSRC_HOME/hub/projects/alpha.json"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
OSRC_HOME="$OSRC_HOME" bash "$SRC" hub serve --port "$PORT" --no-open >"$TMP/serve.log" 2>&1 &
SRV=$!
URL=""; for _ in $(seq 1 60); do URL="$(grep -o 'http://127\.0\.0\.1:[0-9]*/?t=[A-Za-z0-9]*' "$TMP/serve.log" | head -1)"; [ -n "$URL" ] && break; sleep 0.25; done
[ -n "$URL" ] || { bad "hub serve did not start: $(head -3 "$TMP/serve.log")"; echo "RESULTS: $pass pass $fail fail"; exit 1; }
B="${URL%%\?*}"; TOK="${URL##*t=}"
post() { curl -s -o "$TMP/body" -w '%{http_code}' -X POST "$B$1" -H 'Content-Type: application/json' "${@:3}" -d "$2"; }
[ "$(post /api/projects/alpha/status '{"status":"shipped"}')" = 403 ] && ok "status: no token -> 403" || bad "status without token not refused"
[ "$(post /api/projects/alpha/status '{"status":"shipped"}' -H 'X-Hub-Token: wrong')" = 403 ] && ok "status: wrong token -> 403" || bad "wrong token accepted"
[ "$(post /api/projects/alpha/status '{"status":"shipped"}' -H "X-Hub-Token: $TOK" -H 'Origin: https://evil.example')" = 403 ] && ok "status: foreign Origin -> 403" || bad "foreign Origin accepted"
[ ! -e "$OSRC_HOME/hub/status/alpha.json" ] && ok "refused requests wrote nothing" || bad "a refused request wrote an override"
for id in '..' '.hidden' '%2e%2e' 'a%2Fb' "$(printf 'x%.0s' $(seq 1 130))" 'a%20b'; do
  c="$(post "/api/projects/$id/status" '{"status":"shipped"}' -H "X-Hub-Token: $TOK")"
  [ "$c" = 400 ] || [ "$c" = 404 ] || bad "bad id '$id' got $c"
done; ok "bad ids rejected (dots, slashes, spaces, overlong)"
[ -n "$(ls "$OSRC_HOME/hub/status" 2>/dev/null)" ] && bad "bad id left a file: $(ls "$OSRC_HOME/hub/status")" || ok "no file written for any bad id"
[ "$(post /api/projects/nosuch/status '{"status":"shipped"}' -H "X-Hub-Token: $TOK")" = 404 ] && ok "unknown project -> 404" || bad "unknown project accepted"
[ "$(post /api/projects/alpha/status '{"status":"archived"}' -H "X-Hub-Token: $TOK")" = 400 ] && ok "only shipped|restore accepted" || bad "bad status value accepted"
c="$(post /api/projects/alpha/status '{"status":"shipped"}' -H "X-Hub-Token: $TOK" -H "Origin: http://127.0.0.1:$PORT")"
[ "$c" = 200 ] && jq -e '.ok and .project.status=="shipped" and .project.shippedBy=="user" and .project.prevStatus=="review"' "$TMP/body" >/dev/null \
  && ok "Mark done: 200, override written, export shows it" || bad "Mark done failed ($c): $(cat "$TMP/body")"
jq -e '.shippedBy=="user" and .status=="shipped"' "$OSRC_HOME/hub/status/alpha.json" >/dev/null && ok "override file under \$OSRC_HOME/hub/status/" || bad "override file wrong"
curl -s -H "X-Hub-Token: $TOK" "$B/api/projects" | jq -e '.projects[]|select(.id=="alpha")|.status=="shipped"' >/dev/null && ok "GET /api/projects reflects Mark done" || bad "projects feed stale after Mark done"
c="$(post /api/projects/alpha/status '{"status":"restore"}' -H "X-Hub-Token: $TOK")"
[ "$c" = 200 ] && jq -e '.project.status=="review" and (.project.shippedBy==null)' "$TMP/body" >/dev/null \
  && ok "Move back restores the previous status" || bad "restore failed ($c): $(cat "$TMP/body")"
[ "$(post /api/answers '{"id":"alpha--D1\n","choice":"x"}' -H "X-Hub-Token: $TOK")" = 400 ] && ok "HTTP: answer id with trailing newline -> 400" || bad "trailing-newline answer id accepted"
# MC-4: the page offers "your own answer" in the note, so a note-only answer must land.
c="$(post /api/answers '{"id":"alpha--N1","choice":"","note":"my own answer"}' -H "X-Hub-Token: $TOK")"
[ "$c" = 200 ] && jq -e '.choice=="" and .note=="my own answer"' "$OSRC_HOME/hub/answers/alpha--N1.json" >/dev/null \
  && ok "note-only answer accepted and stored" || bad "note-only answer refused ($c): $(cat "$TMP/body")"
[ "$(post /api/answers '{"id":"alpha--N2","note":"no choice key at all"}' -H "X-Hub-Token: $TOK")" = 200 ] && ok "answer without a choice key accepted" || bad "missing choice key refused"
[ "$(post /api/answers '{"id":"alpha--N3","choice":"  ","note":" "}' -H "X-Hub-Token: $TOK")" = 400 ] && ok "blank choice + blank note -> 400" || bad "empty answer accepted"
[ "$(post /api/answers '{"id":"alpha--N4","choice":"yes","note":["x"]}' -H "X-Hub-Token: $TOK")" = 400 ] && ok "non-string note -> 400" || bad "non-string note accepted"
[ ! -e "$OSRC_HOME/hub/answers/alpha--N3.json" ] && [ ! -e "$OSRC_HOME/hub/answers/alpha--N4.json" ] && ok "refused answers wrote nothing" || bad "a refused answer wrote a file"
ct="$(curl -s -o /dev/null -D - "$B/assets/hub-home.js" | tr -d '\r' | grep -i '^content-type:')"
grep -qi 'text/javascript' <<<"$ct" && ok "hub-home.js served as text/javascript (nosniff-safe)" || bad "hub-home.js content type: $ct"
[ "$(curl -s "$B/assets/hub-home.js" | head -c 2)" = "/*" ] && ok "hub-home.js served token-free from /assets" || bad "hub-home.js not served"
csp="$(curl -s -D - -o /dev/null "$B/" | grep -i 'content-security-policy')"
grep -q "script-src 'self' 'sha256-" <<<"$csp" && ok "CSP: script-src self (asset) + hash (inline)" || bad "CSP wrong: $csp"
n_inline="$(grep -c '<script>' "$PAGE")"; n_hash="$(grep -o "'sha256-" <<<"$csp" | wc -l | tr -d ' ')"
[ "$n_inline" = "$n_hash" ] && ok "every inline <script> block is hashed ($n_hash)" || bad "inline blocks $n_inline vs hashes $n_hash"

echo "RESULTS: $pass pass $fail fail"
[ "$fail" -eq 0 ]
