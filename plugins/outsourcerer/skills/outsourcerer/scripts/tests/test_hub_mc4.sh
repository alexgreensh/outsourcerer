#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_hub_mc4.sh -- Mission Control on REAL-shaped data (MC4, 0.16.3). Seeds the shapes Alex's machine had on
# 0.16.2 (out/mc-0162-live.png): a limits cache written by 0.16.0 ("renews":"in 92h 32m"), Outsourcerer tmux
# lane names (outsourcerer-<folder>--<hash>-<sid8>), a job lane with no task, and a /rename slug title
# ("total-recall-85"). Asserts the export renders renew dates and human names, then a GUARD scans every
# display field of the export for id-like tokens. No real tmux: a PATH shim answers has-session for the
# seeded lanes only. Sandboxed HOME + OSRC_HOME.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/.."
ENG="$S/outsourcerer.sh"
[ -f "$ENG" ] || { echo "FAIL: cannot find $ENG"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d "${TMPDIR%/}/.hub-mc4.XXXXXX")" || { echo "FAIL: no scratch dir"; exit 1; }
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" OSRC_HOME="$T/osrc" XDG_CONFIG_HOME="$T/xdg" OSRC_CLAUDE_PROJECTS_DIR="$T/home/.claude/projects"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
unset CLAUDE_CODE_SESSION_ID OSRC_HUB_FAST TMUX
mkdir -p "$HOME" "$OSRC_HOME/sessions" "$OSRC_HOME/jobs" "$XDG_CONFIG_HOME" "$T/bin" "$OSRC_CLAUDE_PROJECTS_DIR"
printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# tmux shim: has-session succeeds for seeded lane names only; nothing else exists. Never touches a real server.
cat > "$T/bin/tmux" <<EOF
#!/bin/sh
[ "\$1" = has-session ] || exit 1
t="\$3"; t="\${t#=}"
grep -qxF "\$t" "$T/live-sessions" 2>/dev/null
EOF
chmod +x "$T/bin/tmux"
NODE="$(command -v node 2>/dev/null || true)"
export PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

now="$(date +%s)"
SA=4fd3a85f-461d-4d07-8e2b-7e95f530648d     # "Prompts" orchestrator (devin video lane)
SC=c41817f1-768f-4c93-8877-7072ff06624e     # Total Recall orchestrator (/rename slug title)
CC=98916108-59ef-4cf2-a6fb-ae14834c941b     # the Claude lane's own session
LA=outsourcerer-video--1285105523-4fd3a85f
LC=outsourcerer-v185-redo--2690552210-c41817f1
JOB=20261113-131318-79b27c9782a0
printf '%s\n%s\n' "$LA" "$LC" > "$T/live-sessions"

# folders: a Prompts tree and a total-recall-core worktree with a GitHub origin
P="$T/work/Prompts/PERSONAL_OS/PROJECTS/agent-self-assessment/proposals/video"
W="$T/work/total-recall-core-worktrees/v185-redo"; WF="$T/work/total-recall-core-worktrees/v185-F4a"
mkdir -p "$P" "$W" "$WF"
for d in "$W" "$WF"; do git -C "$d" init -q && git -C "$d" remote add origin git@github.com:alexgreensh/total-recall-core.git; done

# ownership + registry (real 0.16.2 field names)
mkdir -p "$OSRC_HOME/owners/$SA" "$OSRC_HOME/owners/$SC"
: > "$OSRC_HOME/owners/$SA/$LA"; : > "$OSRC_HOME/owners/$SC/$LC"; : > "$OSRC_HOME/owners/$SC/$JOB"
{
  jq -cn --arg s "$LA" --arg cwd "$P" '{schema_version:"1",event:"start",session_id:$s,provider:"devin",model:"glm-5.2",resolved_model:"glm-5.2",cc_session_id:null,cwd:$cwd,owner:"managed",ts:"2026-11-15T21:27:24Z"}'
  jq -cn --arg s "$LC" --arg cwd "$W" --arg cc "$CC" '{schema_version:"1",event:"start",session_id:$s,provider:"cc",model:"fable",resolved_model:"fable",cc_session_id:$cc,cwd:$cwd,owner:"managed",ts:"2026-11-15T21:30:00Z"}'
} > "$OSRC_HOME/sessions/registry.jsonl"
mkdir -p "$OSRC_HOME/jobs/$JOB"
jq -cn --arg id "$JOB" --arg cwd "$WF" --arg st "$((now - 600))" '{id:$id,provider:"cc",verb:"yolo",model:"z-ai/glm-5.2",tier:"capable",cwd:$cwd,started:$st,lane:"or"}' > "$OSRC_HOME/jobs/$JOB/meta.json"
echo running > "$OSRC_HOME/jobs/$JOB/status"

# transcripts: the orchestrators (fresh, so they are active) and the Claude lane
tr_dir() { local d="$OSRC_CLAUDE_PROJECTS_DIR/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')"; mkdir -p "$d"; printf '%s' "$d"; }
{ printf '{"type":"user","message":{"role":"user","content":"Run the attention essay lanes"}}\n'
  printf '{"type":"ai-title","aiTitle":"Attention essay with Tom'"'"'s comments","sessionId":"%s"}\n' "$SA"; } > "$(tr_dir "$T/work/Prompts")/$SA.jsonl"
{ printf '{"type":"user","message":{"role":"user","content":"continue the TR release"}}\n'
  printf '{"type":"ai-title","aiTitle":"Total Recall 1.9.85 orchestrator handover","sessionId":"%s"}\n' "$SC"
  printf '{"type":"agent-name","agentName":"total-recall-85","sessionId":"%s"}\n' "$SC"
  printf '{"type":"custom-title","customTitle":"total-recall-85","sessionId":"%s"}\n' "$SC"; } > "$(tr_dir "$W")/$SC.jsonl"
{ printf '{"type":"user","message":{"role":"user","content":"Read the brief"}}\n'
  printf '{"type":"ai-title","aiTitle":"F-TEST brief in total-recall","sessionId":"%s"}\n' "$CC"; } > "$(tr_dir "$W")/$CC.jsonl"

# A limits cache in the exact 0.16.0 shape (lib/limits.sh _osrc_summary_json at v0.16.0: renews = "in " +
# _human_eta), plus a 0.16.0 local-builder row (renews only, no renews_at).
RA=$((now + 4 * 86400 + 3600)); RB=$((now + 5 * 86400 + 7200)); mkdir -p "$OSRC_HOME/hub"
jq -cn --argjson ra "$RA" --argjson rb "$RB" '[
  {id:"claude",name:"Claude",lane:"cc",order:1,state:"ok",left:"95% left",renews:"in 92h 32m",renews_at:$ra,cap:null,cap_tripped:false,paid:false,billing:"subscription",window:"7d",used:5,updated:"22:27",updatedAt:"2026-11-15T20:27:00Z",source:"outsourcerer",
   windows:{"5h":{used:5,left:95,renews_at:$ra,renews:"in 3h 2m"}}},
  {id:"codex",name:"Codex / ChatGPT",lane:"cx",order:2,state:"ok",left:"59% left",renews:"in 120h 6m",renews_at:$rb,billing:"subscription",updated:"22:27",updatedAt:"2026-11-15T20:27:00Z"},
  {id:"chatgpt-weekly",name:"ChatGPT — weekly",state:"ok",order:4,billing:"subscription",left:"41% left",renews:"in 120h 6m",updated:"22:27"}]' > "$OSRC_HOME/hub/limits-cache.json"

# gh shim: read-only list calls answered from fixtures; anything else fails and is logged.
GHN="$(date -u -r $((now - 3600)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((now - 3600))" +%Y-%m-%dT%H:%M:%SZ)"
cat > "$T/bin/gh" <<EOF
#!/bin/sh
echo "\$*" >> "$T/gh.log"
[ -f "$T/gh-offline" ] && exit 1
case "\$1 \$2" in
  "release list") printf '[{"tagName":"v1.9.85","name":"Total Recall 1.9.85","publishedAt":"$GHN","isDraft":false}]' ;;
  "pr list") printf '[{"number":71,"title":"Fix hub names","closedAt":"$GHN","mergedAt":"$GHN","url":"https://github.com/alexgreensh/total-recall-core/pull/71"},{"number":70,"title":"Drop idea","closedAt":"$GHN","mergedAt":null,"url":"https://github.com/alexgreensh/total-recall-core/pull/70"}]' ;;
  "issue list") printf '[{"number":62,"title":"Stale guidance","closedAt":"$GHN","url":"https://github.com/alexgreensh/total-recall-core/issues/62","stateReason":"COMPLETED"}]' ;;
  *) echo "gh shim: refused \$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$T/bin/gh"
echo done > "$OSRC_HOME/jobs/$JOB/status"

X="$(OSRC_HUB_FAST=1 bash "$ENG" hub export 2>"$T/err")"; rc=$?
[ "$rc" = 0 ] && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$X" && ok "hub export runs on the real-shaped seed" || { bad "export rc=$rc $(head -c 400 "$T/err")"; echo "RESULT: $pass passed, $fail failed"; exit 1; }
[ -n "${MC4_DUMP:-}" ] && printf '%s\n' "$X" > "$MC4_DUMP"

echo "=== 1. renews: rebuilt from renews_at, never a stored string ==="
# expected text, computed the same way the engine does (local time)
expA="$(OSRC_SOURCED=1 bash -c '. "$1"; _osrc_renew_text "$2"' _ "$ENG" "$RA")"
case "$expA" in "in 4 days · "???" "*) ok "renew text helper says 'in N days · Ddd D Mon' ($expA)" ;; *) bad "unexpected helper text: $expA" ;; esac
jq -e --arg e "$expA" '.limits[] | select(.id == "claude") | .renews == $e' >/dev/null <<<"$X" && ok "0.16.0 cache row 'in 92h 32m' exports as '$expA'" || bad "claude renews: $(jq -c '.limits[] | select(.id=="claude") | .renews' <<<"$X")"
jq -e --arg e "$expA" '.limits[] | select(.id == "claude") | .windows["5h"].renews == $e' >/dev/null <<<"$X" && ok "window detail renews rebuilt too" || bad "window renews: $(jq -c '.limits[] | select(.id=="claude") | .windows' <<<"$X")"
jq -e '.limits[] | select(.id == "codex") | .renews | test("^in 5 days · [A-Z][a-z]{2} [0-9]{1,2} [A-Z][a-z]{2}$")' >/dev/null <<<"$X" && ok "codex 'in 120h 6m' exports as a date" || bad "codex renews: $(jq -c '.limits[] | select(.id=="codex") | .renews' <<<"$X")"
jq -e '.limits[] | select(.id == "chatgpt-weekly") | (.renews // null) == null' >/dev/null <<<"$X" && ok "a stored string with no epoch is dropped, not shown" || bad "epoch-less row kept: $(jq -c '.limits[] | select(.id=="chatgpt-weekly")' <<<"$X")"
jq -r '[.limits[] | .renews, (.windows // {} | .[] | .renews)] | .[] | strings' <<<"$X" | grep -E '[0-9]+h [0-9]+m' && bad "an 'Nh Nm' renew string survived" || ok "no 'Nh Nm' renew string anywhere in limits"
# a past epoch renders nothing
PST="$(jq -c --argjson p "$((now - 60))" '[{id:"x",renews:"in 2h 1m",renews_at:$p}]' <<<'null')"
OUT="$(OSRC_SOURCED=1 bash -c '. "$1"; _osrc_hub_limits_fresh <<<"$2"' _ "$ENG" "$PST")"
jq -e '.[0].renews == null' >/dev/null <<<"$OUT" && ok "a renews_at already past renders no renew text" || bad "past epoch: $OUT"
# the local builder now carries the epoch, so a cached local row can be rebuilt later
grep -q 'renews_at:(\$rat|tonumber)' "$S/lib/hub.sh" && ok "local builder rows carry renews_at" || bad "local builder rows lack renews_at"

echo "=== 2. names: never a session id, hash, sid or slug ==="
lanes="$(jq -r '.projects[].lanes[]?.short' <<<"$X")"
printf '%s\n' "$lanes" | grep -qx 'Video' && ok "devin tmux lane reads 'Video' (folder), not $LA" || bad "video lane name: $lanes"
printf '%s\n' "$lanes" | grep -qx 'F-TEST brief in total-recall' && ok "Claude lane reads its own transcript title" || bad "claude lane name: $lanes"
printf '%s\n' "$lanes" | grep -qx 'V185 F4a' && ok "job lane with no task reads its folder 'V185 F4a', not 'or yolo <hex>'" || bad "job lane name: $lanes"
names="$(jq -r '.projects[].name' <<<"$X")"
printf '%s\n' "$names" | grep -q 'Total Recall 1.9.85 orchestrator handover' && ok "slug /rename title skipped for the ai-title" || bad "project names: $names"
printf '%s\n' "$names" | grep -q 'total-recall-85' && bad "slug title still on a card" || ok "no 'total-recall-85' on a card"
D="$(OSRC_SOURCED=1 bash -c '. "$1"; _osrc_hub_folder_label "$2"; _osrc_hub_folder_label "$3"; printf "[%s]" "$(_osrc_hub_folder_label "$4")"' _ "$ENG" "/x/v185-redo" "$LA" "/x/9f8e7d6c5b4a")"
[ "$D" = "$(printf 'V185 redo\nVideo\n[]')" ] && ok "folder labels: 'V185 redo', 'Video', hex folder -> empty" || bad "folder labels: $(printf '%s' "$D" | tr '\n' '|')"

echo "=== GUARD: no display field in the export reads like an id ==="
# Display fields only: id/key/session/endpoint fields are how the page addresses things, never text it prints.
leaks="$(jq -r '
  def idlike: test("(^|[^A-Za-z0-9])(osrc|outsourcerer)-"; "i") or test("--[0-9]")
    or test("(?<![A-Za-z0-9])(?=[0-9a-fA-F]*[0-9])[0-9a-fA-F]{6,}(?![A-Za-z0-9])") or test("^[a-z0-9]+([-_][a-z0-9]+)*[-_][0-9]+[a-z]?$");
  [ (.projects[] | .name, .tagline, (.lanes[]? | .short)),
    (.also[]? | .name, .title, .project),
    (.limits[] | .name, .renews, (.windows // {} | .[] | .renews)) ]
  | .[] | strings | select(idlike)' <<<"$X")"
[ -z "$leaks" ] && ok "guard: no hex runs, --digits, osrc-/outsourcerer- prefixes or numbered slugs in names" || bad "guard found id-like display text: $(printf '%s' "$leaks" | tr '\n' '|')"
# the guard's own predicate must bite on every 0.16.2 leak
for s in "$LA" "outsourcerer-v185-redo--269…" "total-recall-85" "osrc-orch2" "or yolo 79b27c9782a0"; do
  jq -en --arg s "$s" "$(sed -n '/^_OSRC_HUB_IDLIKE_JQ=/,/;.$/p' "$S/lib/hub-lanename.sh" | sed "1s/^_OSRC_HUB_IDLIKE_JQ='//; \$s/'\$//")"' $s | idlike' >/dev/null 2>&1 && ok "idlike catches '$s'" || bad "idlike missed '$s'"
done
for s in "Video" "V185 redo" "Total Recall Core" "F-TEST brief in total-recall" "10x-animation" "FABLE-BRIEF-2026-11-15 video proposal" "Outsourcerer 0.16.2"; do
  jq -en --arg s "$s" "$(sed -n '/^_OSRC_HUB_IDLIKE_JQ=/,/;.$/p' "$S/lib/hub-lanename.sh" | sed "1s/^_OSRC_HUB_IDLIKE_JQ='//; \$s/'\$//")"' $s | idlike' >/dev/null 2>&1 && bad "idlike flags a real name '$s'" || ok "idlike leaves '$s' alone"
done

echo "=== 7. History: lanes + releases + PRs + issues, cached, read-only ==="
H="$(jq -c --arg s "$SC" '.projects[] | select(.id == $s) | .history' <<<"$X")"
jq -e '.repo == "alexgreensh/total-recall-core" and .github == "ok"' >/dev/null <<<"$H" && ok "history repo from the lanes' git remote, GitHub reachable" || bad "history head: $(jq -c '{repo,github}' <<<"$H")"
jq -e '[.items[] | select(.kind == "release" and .title == "Total Recall 1.9.85" and (.url | startswith("https://github.com/alexgreensh/total-recall-core/releases/tag/")))] | length == 1' >/dev/null <<<"$H" && ok "release listed with its link" || bad "release: $(jq -c '[.items[]|select(.kind=="release")]' <<<"$H")"
jq -e '[.items[] | select(.kind == "pr")] | map("\(.number):\(.outcome)") | sort == ["70:closed","71:merged"]' >/dev/null <<<"$H" && ok "PR #71 merged, PR #70 closed unmerged" || bad "prs: $(jq -c '[.items[]|select(.kind=="pr")]' <<<"$H")"
jq -e '[.items[] | select(.kind == "issue" and .number == 62)] | length == 1' >/dev/null <<<"$H" && ok "closed issue #62 listed" || bad "issues: $(jq -c '[.items[]|select(.kind=="issue")]' <<<"$H")"
jq -e '[.items[] | select(.kind == "lane")] | map("\(.title)=\(.outcome)") | sort == ["F-TEST brief in total-recall=running","V185 F4a=finished"]' >/dev/null <<<"$H" && ok "every lane with outcome: live Claude lane running, finished job green" || bad "lanes: $(jq -c '[.items[]|select(.kind=="lane")|{title,outcome}]' <<<"$H")"
jq -e '.summary.prsMerged == 1 and .week.releases == 1 and .week.issuesClosed == 1' >/dev/null <<<"$H" && ok "summary + this-week counts" || bad "summary: $(jq -c '{summary,week}' <<<"$H")"
grep -vE '^(release|pr|issue) list ' "$T/gh.log" | grep -q . && bad "gh called with a non-list command: $(cat "$T/gh.log")" || ok "gh used read-only (list calls only)"
c1="$(wc -l < "$T/gh.log")"; OSRC_HUB_FAST=1 bash "$ENG" hub export >/dev/null 2>&1; c2="$(wc -l < "$T/gh.log")"
[ "$c1" = "$c2" ] && ok "second export served GitHub data from the 10-minute cache" || bad "gh re-called within TTL ($c1 -> $c2)"
touch "$T/gh-offline"; git -C "$WF" commit -q --allow-empty -m x >/dev/null 2>&1; git -C "$WF" tag v1.9.84 >/dev/null 2>&1
HO="$(OSRC_HUB_GH_TTL=0 bash "$ENG" hub export 2>/dev/null | jq -c --arg s "$SC" '.projects[] | select(.id == $s) | .history')"
jq -e '.github == "unreachable" and ([.items[] | select(.kind == "release" and .local == true and .tag == "v1.9.84")] | length == 1)' >/dev/null <<<"$HO" && ok "offline: GitHub not reachable flag + local git tags" || bad "offline: $(jq -c '{github, r:[.items[]|select(.kind=="release")]}' <<<"$HO")"
rm -f "$T/gh-offline"
HJS="$S/lib/hub-assets/hub-history.js"
grep -q "Finished (' + done.length" "$HJS" && grep -q 'finishedFold({ el, ic }, p, false)' "$S/lib/hub-assets/hub-home.js" && grep -q 'OSRC_HUB_HISTORY.section({ el, ic }, p)' "$S/lib/hub.html" \
  && ok "page: Finished (N) fold open on the project page, collapsed on Home; History section wired" || bad "history page wiring missing"
grep -q 'GitHub not reachable' "$HJS" && ok "page says 'GitHub not reachable' in one neutral line" || bad "offline line missing"
grep -q "plans: lims" "$S/lib/hub-assets/hub-home.js" && ok "plans tile lists every checked plan (#5)" || bad "plans tile still shows one plan"

echo "=== 3. page: header on one line, neutral stale pill, page-side guards ==="
CSS="$S/lib/hub-assets/hub-mc3.css"; HJ="$S/lib/hub-assets/hub-home.js"; PG="$S/lib/hub.html"
grep -q '\.lst\.stale, \.stamp-top\.stale { color: var(--ink); background: transparent' "$CSS" && ok "stale stamp is a neutral outline pill" || bad "stale stamp still red"
grep -q '\.rail h2:has(#lstamp) { flex-wrap: nowrap' "$CSS" && grep -q '#lstamp \.rfr { flex: none' "$CSS" && grep -q '#lstamp \.lstt {.*text-overflow: ellipsis' "$CSS" \
  && ok "plans header: no wrap, stamp ellipsizes, refresh never shrinks" || bad "plans header CSS missing"
grep -q "OSRC_HUB_CLEAN.limit(l)" "$PG" && grep -q "OSRC_HUB_CLEAN.project(p)" "$PG" && ok "page passes limits and projects through the MC4 cleaners" || bad "page does not clean intake"
grep -q "'Session: ' + l.session" "$PG" && bad "lane hover still prints the session id" || ok "lane hover no longer prints the session id"
if [ -n "$NODE" ]; then
  NJ="$("$NODE" -e '
    global.window = {}; require(process.argv[1]); const C = window.OSRC_HUB_CLEAN, now = Date.UTC(2026, 10, 16, 10, 0) ;
    const a = C.limit({ renews: "in 92h 32m" }, now), b = C.limit({ renews: "x", renews_at: now / 1000 + 4 * 86400 }, now);
    const p = C.project({ name: "Total Recall Core · total-recall-85", lanes: [{ short: "outsourcerer-video--1285105…", model: "glm-5.2" }, { short: "Video" }] });
    console.log(JSON.stringify({ a: a.renews === undefined, b: /^in 4 days · [A-Z][a-z]{2} \d{1,2} [A-Z][a-z]{2}$/.test(b.renews), n: p.name, l0: p.lanes[0].short, l1: p.lanes[1].short }));' "$HJ" 2>&1)"
  [ "$NJ" = '{"a":true,"b":true,"n":"Total Recall Core","l0":"Lane · glm-5.2","l1":"Video"}' ] && ok "page cleaners: drop 'Nh Nm', rebuild from renews_at, strip slug/id names" || bad "page cleaners: $NJ"
else echo "SKIP: node not installed (page cleaner unit)"; fi
[ "$(wc -l < "$PG" | tr -d ' ')" -le 1000 ] && ok "hub.html stays within 1,000 lines" || bad "hub.html over 1,000 lines"

echo "=== symlinked engine still loads lib/hub-lanename.sh ==="
ln -s "$ENG" "$T/osrc-link"
OSRC_SOURCED=1 bash -c '. "$1"; type _osrc_hub_lane_name >/dev/null && type _osrc_hub_limits_fresh >/dev/null' _ "$T/osrc-link" && ok "lib functions load through a symlink" || bad "lib not loaded through symlink"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
