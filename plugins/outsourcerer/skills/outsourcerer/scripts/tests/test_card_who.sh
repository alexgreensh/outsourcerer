#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_card_who.sh -- a Mission Control hover card says who did the work.
#   1. A board track keeps lane, reviewer, PRs, branch, worktree and repo (board-level repo too).
#   2. Tracks with no model or no lane are listed by name.
#   3. The card nag fires for a FRESH card whose tracks are unnamed, and stays quiet once named.
#   4. Supervise's tick turns that nag into an EVENT card for the owning session only.
#   5. hub report --board warns at publish time about unnamed tracks.
#   6. The real hover-card code (lib/hub.html laneTile, run in node) prints lane, model, reviewer, PRs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "${TMPDIR%/}/.test-card-who.XXXXXX")" || { echo "FAIL: no scratch dir" >&2; exit 1; }
TEST_TMP="$TMP"; trap 'rm -rf "$TEST_TMP"' EXIT
pass=0; fail=0; ok() { echo "PASS: $1"; pass=$((pass + 1)); }; bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
HOME="$TMP/home"; OSRC_HOME="$TMP/state"; export HOME OSRC_HOME; mkdir -p "$HOME" "$OSRC_HOME/hub/projects"
unset CLAUDE_CODE_SESSION_ID; set --; . "$SRC" >/dev/null 2>&1

# 1. Pass-through.
base='{"id":"p1","name":"Test","lanes":[]}'
card='{"board":{"repo":"o/r","tasks":[{"short":"Watchdog","model":"Opus 5.5","lane":"Claude cloud","reviewer":"Fable","prs":"#80","issues":"#84","branch":"cloud/x","worktree":"","pct":100},{"short":"Disk","model":"Sonnet 5.5","lane":7}]}}'
out="$(_osrc_hub_apply_board "$base" "$card")"
jq -e '.repo == "o/r" and .lanes[0].lane == "Claude cloud" and .lanes[0].reviewer == "Fable" and .lanes[0].prs == "#80"
       and .lanes[0].issues == "#84" and .lanes[0].branch == "cloud/x" and .lanes[0].repo == "o/r"
       and (.lanes[0] | has("worktree") | not) and (.lanes[1] | has("lane") | not)' >/dev/null <<<"$out" \
  && ok "board tracks keep lane, reviewer, PRs, branch and repo; empty or non-string values are dropped" \
  || bad "board pass-through: $out"

# 2. Unnamed tracks.
sid=sess-card; pf="$OSRC_HOME/hub/projects/$sid.json"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg t "$now_iso" '{name:"Test",reportedAt:$t,board:{tasks:[{short:"Watchdog",model:"Opus 5.5",lane:"Claude cloud"},{short:"Disk",model:"Sonnet 5.5"},{short:"Alerts"}]}}' > "$pf"
[ "$(_sg_board_unnamed "$pf")" = "Disk, Alerts" ] && ok "tracks with no model or lane are listed by name" || bad "unnamed: '$(_sg_board_unnamed "$pf")'"

# 3. Nag on a fresh card with unnamed tracks; quiet once named.
r="$(_sg_card_nag "$sid")" && case "$r" in *"do not say who built them: Disk, Alerts"*'"model" and "lane"'*) true ;; *) false ;; esac \
  && ok "a fresh card with unnamed tracks is still nagged, with the fields to add" || bad "nag: rc=$? $r"
rm -f "$OSRC_HOME/hub/card-nag/$sid"
jq '.board.tasks |= map(.model = (.model // "Opus 5.5") | .lane = (.lane // "Claude cloud"))' "$pf" > "$pf.t" && mv "$pf.t" "$pf"
_sg_card_nag "$sid" >/dev/null && bad "a fresh, fully named card was nagged" || ok "a fresh card that names every track is left alone"

# 4. Supervise tick event, owner-scoped.
rm -f "$OSRC_HOME/hub/card-nag/$sid"
jq '.board.tasks[1].lane = ""' "$pf" > "$pf.t" && mv "$pf.t" "$pf"
_sv_card_event "$sid"
ev="$OSRC_HOME/lanes/events.jsonl"
jq -e -s --arg s "$sid" 'length == 1 and .[0].kind == "card" and .[0].target == "card" and .[0].owner == $s
     and (.[0].detail | test("Disk")) and (.[0].next | test("hub report --board"))' "$ev" >/dev/null 2>&1 \
  && ok "the supervise tick logs one EVENT card for the owning session" || bad "card event: $(cat "$ev" 2>/dev/null)"
_sv_card_event "$sid"
[ "$(wc -l < "$ev" | tr -d ' ')" = 1 ] && ok "the next tick inside the same window does not repeat it" || bad "card event repeated"
_sv_card_event no-such-session; [ "$(wc -l < "$ev" | tr -d ' ')" = 1 ] && ok "a session with no card gets no event" || bad "event for a cardless session"

# 5. Publish-time warning.
jq -n '{tasks:[{short:"Watchdog that never sleeps",model:"Opus 5.5",lane:"Claude cloud",pct:50},{short:"Disk floor per user",pct:10}]}' > "$TMP/board.json"
w="$(CLAUDE_CODE_SESSION_ID=sess-pub cmd_hub_report --board "$TMP/board.json" 2>&1 >/dev/null)"
case "$w" in *'name no "model" or "lane"'*"Disk floor per user"*) ok "hub report --board warns about unnamed tracks" ;; *) bad "publish warning: $w" ;; esac
ls "$TMP"/board.json.osrc-chk.* >/dev/null 2>&1 && bad "check copy left next to the board" || ok "no temp copy left next to the board"

# 6. The real hover card.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/card.js" <<'EOF'
const fs = require('fs'); const html = fs.readFileSync(process.argv[2], 'utf8');
const a = html.indexOf('const laneTile = (l) => {'); const b = html.indexOf('\n    };\n', a);
if (a < 0 || b < 0) { console.log('NOCODE'); process.exit(0); }
const mk = (cls, text) => ({ cls, text: text || '', kids: [], append(...k) { this.kids.push(...k); }, appendChild(k) { this.kids.push(k); },
  setAttribute() {}, addEventListener() {} });
const el = (t, cls, text) => mk(cls, text); let hv = null;
const hover = (c, fn) => { hv = fn; }; const ring = () => mk(); const chip = (s) => mk('chip', s); const logo = () => mk();
const pctOk = (x) => typeof x.pct === 'number'; const hide = () => {}; const openSession = () => {};
const refs = (repo, s) => { const n = String(s || '').match(/#\d+/g); return n && repo ? mk('refs', n.join(' ')) : null; };
const document = { createTextNode: (t) => mk(null, t) }; const p = { id: 'p1', repo: 'o/r' };
const laneTile = eval('(' + html.slice(a + 'const laneTile = '.length, b) + '\n})');
laneTile({ id: 'T1', short: 'Watchdog', status: 'merged', pct: 100, model: 'Opus 5.5', lane: 'Claude cloud', reviewer: 'Fable', issues: '#84', prs: '#80 #82' });
const h = mk(); hv(h); const out = []; const walk = (n) => { if (n.text) out.push(n.text); n.kids.forEach(walk); }; walk(h);
console.log(out.join(' | '));
EOF
  c="$(node "$TMP/card.js" "$HERE/../lib/hub.html" 2>&1)"
  case "$c" in *"Opus 5.5"*"Lane: Claude cloud"*"Reviewed by: Fable"*"#84 #80 #82"*) ok "the hover card shows model, lane, reviewer and issue + PR links ($c)" ;;
    *) bad "hover card: $c" ;; esac
else ok "hover card: node not installed, skipped"; fi

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
