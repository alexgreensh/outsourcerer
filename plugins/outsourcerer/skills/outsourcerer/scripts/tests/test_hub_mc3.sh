#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_hub_mc3.sh -- Mission Control that is never empty: heartbeat visibility for an orchestrator
# between lanes, finished lanes kept, no spam from sessions that never used Outsourcerer, `hub report`,
# renewal text at three ranges (CLI table + export), the empty state, "Also running" rows and the
# session-title priority. Sandboxed HOME + OSRC_HOME; no tmux; the only processes are our own sleeps.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/.."
ENG="$S/outsourcerer.sh"
[ -f "$ENG" ] || { echo "FAIL: cannot find $ENG"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d "${TMPDIR%/}/.hub-mc3.XXXXXX")" || { echo "FAIL: no scratch dir"; exit 1; }
cleanup() { mc3_unseed 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
export MC3_T="$T" HOME="$T/home" OSRC_HOME="$T/osrc" XDG_CONFIG_HOME="$T/xdg" MC3_ENGINE="$ENG"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
unset CLAUDE_CODE_SESSION_ID OSRC_HUB_FAST
mkdir -p "$HOME" "$OSRC_HOME" "$XDG_CONFIG_HOME"
printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"
. "$HERE/lib_mc3_seed.sh"
export PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
eng() { bash "$ENG" "$@"; }
as()  { local s="$1"; shift; CLAUDE_CODE_SESSION_ID="$s" bash "$ENG" "$@"; }
ago() { touch -t "$(date -r $(( $(date +%s) - $1 )) +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$(( $(date +%s) - $1 ))" +%Y%m%d%H%M.%S)" "$2"; }

echo "=== empty state: nothing has run ==="
E="$(eng hub export 2>"$T/err")"; rc=$?
[ "$rc" = 0 ] && jq -e '.projects == [] and .also == []' >/dev/null <<<"$E" && ok "empty machine exports projects:[] and also:[] cleanly" || bad "empty export: rc=$rc $(head -c 300 <<<"$E") $(head -c 300 "$T/err")"
HJ="$S/lib/hub-assets/hub-home.js"
grep -q "'Nothing is running right now'" "$HJ" && grep -q 'outsourcerer bg edit' "$HJ" && ok "empty page says nothing is running and how to start" || bad "empty-state copy missing from hub-home.js"
grep -q "No projects yet" "$HJ" && bad "old empty headline still present" || ok "old 'No projects yet' headline gone"

echo "=== seed: orchestrators, a between-lanes session, other sessions ==="
mc3_seed
X="$(eng hub export)"
names="$(jq -r '.projects[].name' <<<"$X")"

echo "=== 1. heartbeat visibility ==="
[ -d "$OSRC_HOME/owners/$MC3_SID_B" ] && bad "seed: stop-guard should have reaped B's owner dir" || ok "stop-guard reaped B's last lane (the real between-lanes shape)"
[ -f "$OSRC_HOME/hub/seen/$MC3_SID_B/.beat" ] && ok "stop-guard beat for a known orchestrator" || bad "no beat for B"
grep -qx "Outsourcerer 0.16.2" <<<"$names" && ok "orchestrator between lanes stays on the page" || bad "B missing: $names"
jq -e --arg s "$MC3_SID_B" '.projects[] | select(.id == $s) | .lanes | length == 1 and .[0].ended == true and .[0].status == "Done" and .[0].short == "Mission Control heartbeat"' >/dev/null <<<"$X" \
  && ok "its finished lane stays listed as finished" || bad "B lanes: $(jq -c --arg s "$MC3_SID_B" '.projects[] | select(.id == $s) | .lanes' <<<"$X")"
G=99999999-7777-4777-8777-777777777777
as "$G" lane ls >/dev/null 2>&1
[ -f "$OSRC_HOME/hub/seen/$G/.beat" ] && ok "an orchestration command (lane ls) writes the heartbeat" || bad "lane ls did not beat"
mkdir -p "$OSRC_HOME/hub/projects"; jq -cn '{name:"Ghost"}' > "$OSRC_HOME/hub/projects/$G.json"
ago $((25 * 3600)) "$OSRC_HOME/hub/projects/$G.json"; ago 7200 "$OSRC_HOME/hub/seen/$G/.beat"   # a card holds a project for OSRC_HUB_STALE_HOURS (24)
eng hub export | jq -e '[.projects[].name] | index("Ghost") == null' >/dev/null && ok "a quiet orchestrator (no beat or transcript for 2h, card 25h old) leaves the page" || bad "stale Ghost still shown"
touch "$OSRC_HOME/hub/seen/$G/.beat"
eng hub export | jq -e '[.projects[].name] | index("Ghost") != null' >/dev/null && ok "its next heartbeat brings it back" || bad "Ghost not back after beat"
ago 7200 "$OSRC_HOME/hub/seen/$G/.beat"
OSRC_HUB_ACTIVE_MIN=240 eng hub export | jq -e '[.projects[].name] | index("Ghost") != null' >/dev/null && ok "OSRC_HUB_ACTIVE_MIN widens the window" || bad "OSRC_HUB_ACTIVE_MIN ignored"
ago $((13 * 3600)) "$OSRC_HOME/hub/seen/$MC3_SID_B/job-b1"
eng hub export | jq -e --arg s "$MC3_SID_B" '[.projects[] | select(.id == $s) | .lanes[]] | length == 0' >/dev/null && ok "finished lanes drop after OSRC_HUB_ENDED_HOURS (12)" || bad "old ended lane kept"
touch "$OSRC_HOME/hub/seen/$MC3_SID_B/job-b1"

echo "=== 2. no spam ==="
grep -q "LinkedIn\|Marketing Site\|Weekly Notes" <<<"$names" && bad "non-Outsourcerer session listed as a project: $names" || ok "busy non-Outsourcerer sessions are never projects"
H=88888888-7777-4777-8777-777777777777
printf '{"session_id":"%s"}' "$H" | as "$H" stop-guard >/dev/null 2>&1
as "$H" tap status >/dev/null 2>&1; as "$H" hub export >/dev/null 2>&1; as "$H" limits >/dev/null 2>&1
[ -e "$OSRC_HOME/hub/seen/$H" ] && bad "the per-turn hook or a read-only command registered a stranger" || ok "stop-guard, tap, hub export and limits never register a session"
CLAUDE_CODE_SESSION_ID="$H" OUTSOURCERER_DEPTH=1 bash "$ENG" lane ls >/dev/null 2>&1
[ -e "$OSRC_HOME/hub/seen/$H" ] && bad "a delegate (depth 1) registered as an orchestrator" || ok "a delegate inside a run is not an orchestrator"

echo "=== 3. hub report ==="
out="$(as "$MC3_SID_A" hub report --name "Total Recall 1.8.6" --status building --pct 62 --eta "Tue 17 Nov" --next "Review the retries lane, then cut the release" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "report accepted: $out" || bad "report rc=$rc: $out"
case "$out" in *"$OSRC_HOME"*|*"$T"*|*/hub/*) bad "report printed a path: $out" ;; *) ok "report never prints paths" ;; esac
P="$(eng hub export | jq -c --arg s "$MC3_SID_A" '.projects[] | select(.id == $s)')"
jq -e '.name == "Total Recall 1.8.6" and .status == "building" and .reported.pct == 62 and .reported.status == "building" and .eta == "Tue 17 Nov" and .next == "Review the retries lane, then cut the release"' >/dev/null <<<"$P" \
  && ok "every field reaches the card (the percent from the report; the report's words while fresh)" || bad "card: $P"
as "$MC3_SID_A" hub report --pct 70 >/dev/null 2>&1
jq -e '.pct == 70 and .eta == "Tue 17 Nov" and .name == "Total Recall 1.8.6"' "$OSRC_HOME/hub/projects/$MC3_SID_A.json" >/dev/null && ok "a later report merges, keeping other fields" || bad "merge lost fields"
as "$MC3_SID_A" hub report --ask "Ship tonight?" --why "The fixes are merged and the free gate is green, so shipping now unblocks users." --rec "Yes, nothing is left." --option "Ship tonight" --option "Wait for tomorrow" --when "Today" --weight Critical >/dev/null \
  && as "$MC3_SID_A" hub report --ask "Bump the version?" --why "Two lanes changed the saved file format, so older builds cannot read new files." --rec "Bump to 1.9 for safety." --option "Bump to 1.9" --option "Keep 1.8" >/dev/null
D="$(eng hub export | jq -c --arg s "$MC3_SID_A" '.projects[] | select(.id == $s) | .decisions')"
jq -e 'length == 2 and .[0].id == "D1" and .[0].weight == "Critical" and .[1].id == "D2" and .[1].weight == "High" and all(.[]; .status == "wait")' >/dev/null <<<"$D" && ok "--ask adds open decisions D1, D2" || bad "asks: $D"
jq -e '.[0].why == "The fixes are merged and the free gate is green, so shipping now unblocks users." and .[0].rec == "Yes, nothing is left." and .[0].options == ["Ship tonight","Wait for tomorrow"] and .[0].when == "Today" and .[1].options == ["Bump to 1.9","Keep 1.8"] and .[1].rec == "Bump to 1.9 for safety."' >/dev/null <<<"$D" \
  && ok "an ask carries its background, pick, deadline and choices to the card" || bad "ask detail: $D"
for args in "--ask Bare?" "--ask Q --why" "--ask Q --rec R" "--ask Q --why W" "--ask Q --why W --option only-one" "--why W" "--option X"; do
  # shellcheck disable=SC2086
  if as "$MC3_SID_A" hub report $args >/dev/null 2>&1; then bad "accepted an ask without context: $args"; else ok "refuses an ask without context: $args"; fi
done
if as "$MC3_SID_A" hub report --ask "Short why?" --why "Too short to explain anything." --rec "Pick A" --option "A" --option "B" >/dev/null 2>&1; then bad "accepted --why under 40 chars"; else ok "refuses --why under 40 chars"; fi
if as "$MC3_SID_A" hub report --ask "No rec?" --why "This background explanation is definitely longer than forty characters." --option "A" --option "B" >/dev/null 2>&1; then bad "accepted --ask without --rec"; else ok "refuses --ask without --rec"; fi
if as "$MC3_SID_A" hub report --ask "No opts?" --why "This background explanation is definitely longer than forty characters." --rec "Pick A" >/dev/null 2>&1; then bad "accepted --ask without 2+ --option"; else ok "refuses --ask without 2+ --option"; fi
jq -e 'length == 2' "$OSRC_HOME/hub/decisions/$MC3_SID_A.json" >/dev/null && ok "a refused ask adds nothing" || bad "a refused ask was saved"
as "$MC3_SID_A" hub report --done-ask D1 >/dev/null
jq -e '.[0].status == "done" and .[1].status == "wait"' "$OSRC_HOME/hub/decisions/$MC3_SID_A.json" >/dev/null && ok "--done-ask closes exactly that question" || bad "done-ask"
for args in "--status flying" "--pct 101" "--pct -3" "--pct 4x" "--name https://github.com/a/b" "--name alexgreensh/total-recall" "--name 0163abcdef0123456789" "--done-ask D9" "--eta" "--weight High" "--bogus 1"; do
  # shellcheck disable=SC2086
  if as "$MC3_SID_A" hub report $args >/dev/null 2>&1; then bad "accepted bad input: $args"; else ok "rejects: $args"; fi
done
eng hub report --pct 5 >/dev/null 2>&1 && bad "report without a Claude session accepted" || ok "report without CLAUDE_CODE_SESSION_ID refuses"
_left="$(ls "$OSRC_HOME/hub/projects" "$OSRC_HOME/hub/decisions" 2>/dev/null)"
grep -q '\.tmp\.' <<<"$_left" && bad "temp files left behind" || ok "atomic writes leave no temp files"
as "$MC3_SID_A" hub report --next "$(printf 'line one\nline\ttwo %s/secret' "$HOME")" >/dev/null
jq -e '.next == "line one line two ~/secret"' "$OSRC_HOME/hub/projects/$MC3_SID_A.json" >/dev/null && ok "text is one clean line, HOME shortened" || bad "next: $(jq -r .next "$OSRC_HOME/hub/projects/$MC3_SID_A.json")"
ln -s "$T/elsewhere.json" "$OSRC_HOME/hub/projects/$G.json.tmp" 2>/dev/null; rm -f "$OSRC_HOME/hub/projects/$G.json"; ln -s "$T/elsewhere.json" "$OSRC_HOME/hub/projects/$G.json"
as "$G" hub report --pct 1 >/dev/null 2>&1 && bad "wrote through a symlinked card" || ok "refuses a symlinked card"
[ -e "$T/elsewhere.json" ] && bad "symlink target was written" || ok "symlink target untouched"
rm -f "$OSRC_HOME/hub/projects/$G.json" "$OSRC_HOME/hub/projects/$G.json.tmp"
as "$MC3_SID_B" hub report --status shipped >/dev/null
jq -e '.status == "shipped" and (.shippedAt | type == "string")' "$OSRC_HOME/hub/projects/$MC3_SID_B.json" >/dev/null && ok "--status shipped stamps shippedAt" || bad "shipped"
S2="$S/../SKILL.md"; R2="$S/../references/hub.md"
grep -q "hub report" "$S2" && grep -q "hub report" "$R2" && ok "SKILL.md and references/hub.md document hub report" || bad "hub report undocumented"

echo "=== 4. renewal text ==="
( . "$S/lib/hub-report.sh"
  export TZ=UTC
  now="$(date -u -j -f '%Y-%m-%d %H:%M:%S' '2026-11-15 12:00:00' +%s 2>/dev/null || date -u -d '2026-11-15 12:00:00' +%s)"
  t1="$(_osrc_renew_text $(( now + 6*3600 + 40*60 )) "$now")"
  t2="$(_osrc_renew_text $(( now + 21*3600 + 10*60 )) "$now")"
  t3="$(_osrc_renew_text $(( now + 92*3600 + 33*60 )) "$now")"
  t4="$(_osrc_renew_text $(( now - 60 )) "$now")"
  [ "$t1" = "today · 18:40" ] && echo "PASS: under 24h, same day: $t1" || echo "FAIL: same day: '$t1'"
  [ "$t2" = "tomorrow · 09:10" ] && echo "PASS: under 24h, next day: $t2" || echo "FAIL: next day: '$t2'"
  [ "$t3" = "in 4 days · Thu 19 Nov" ] && echo "PASS: 92h 33m reads in days: $t3" || echo "FAIL: days: '$t3'"
  [ -z "$t4" ] && echo "PASS: a past reset prints nothing" || echo "FAIL: past: '$t4'"
  export TZ=XST-2   # POSIX UTC+2 (no zoneinfo needed in the sandbox): 22:30 UTC is 00:30 the next local day
  t5="$(_osrc_renew_text $(( now + 10*3600 + 30*60 )) "$now")"
  [ "$t5" = "tomorrow · 00:30" ] && echo "PASS: local time zone decides today/tomorrow: $t5" || echo "FAIL: tz: '$t5'"
) > "$T/renew.out"
cat "$T/renew.out"; pass=$((pass + $(grep -c '^PASS' "$T/renew.out"))); fail=$((fail + $(grep -c '^FAIL' "$T/renew.out")))
L="$(eng lane summary 2>&1)"
# Midnight-safe: 92h ahead is "in 3 days" or "in 4 days" depending on the hour the suite runs.
grep -Eq "in [34] days · [A-Z][a-z]{2} [0-9]{1,2} [A-Z][a-z]{2}" <<<"$L" && ok "CLI limits table says days + date" || bad "CLI table: $L"
grep -Eq '[0-9]+h [0-9]+m' <<<"$L" && bad "CLI table still counts hours: $L" || ok "CLI table never counts hours"
grep -q "syntax error" <<<"$L" && bad "CLI table crashed under bash 3.2: $L" || ok "CLI table renders under /bin/bash"
eng hub export | jq -e '[.limits[] | select(.renews != null)] | length > 0 and all(.[]; .renews | test("^(today|tomorrow) · [0-2][0-9]:[0-5][0-9]$|^in [0-9]+ days · [A-Z][a-z]{2} [0-9]{1,2} [A-Z][a-z]{2}$"))' >/dev/null \
  && ok "export renewals use the same wording" || bad "export renews: $(eng hub export | jq -c '[.limits[].renews]')"
grep -q "(st === 'ok' || st === 'low' ? 'Renews ' : 'Back ')" "$S/lib/hub.html" && ok "page says Renews for a working plan, Back only when out" || bad "page renew label"

echo "=== 5. also running ==="
before="$(cd "$HOME/.claude/sessions" && ls -la | cksum)"
A="$(eng hub export | jq -c '.also')"
after="$(cd "$HOME/.claude/sessions" && ls -la | cksum)"
jq -e 'any(.[]; .name == "Marketing Site · Write a LinkedIn post" and .state == "working" and .model == "Opus 5.5")' >/dev/null <<<"$A" && ok "a working session: Project · title, model, state" || bad "C row: $A"
jq -e 'any(.[]; (.name | startswith("Weekly Notes · Draft the launch post")) and .state == "idle" and (.idleMin | type == "number"))' >/dev/null <<<"$A" && ok "a recently idle session shows as idle N min" || bad "D row: $A"
jq -e 'all(.[]; (.name | test("Old idle chat")) | not)' >/dev/null <<<"$A" && ok "a session idle for hours never shows" || bad "E shown: $A"
jq -e 'all(.[]; (.name | test("TR v1.8.6|Total Recall 1.8.6")) | not)' >/dev/null <<<"$A" && ok "an orchestrator is not repeated under Also running" || bad "A repeated: $A"
jq -e 'all(.[]; (tostring | test("[0-9a-f]{8}-[0-9a-f]{4}|/Users/|/home/|\\.mc3|github\\.com")) | not)' >/dev/null <<<"$A" && ok "rows carry no ids or paths" || bad "leak: $A"
[ "$before" = "$after" ] && ok "read-only: the Claude sessions folder is untouched" || bad "sessions dir changed"

echo "=== 6. titles ==="
jq -e 'any(.[]; .name == "Marketing Site · Total Recall Core")' >/dev/null <<<"$A" && ok "agent-name cleaned: [cloud] owner/ and the id dropped" || bad "agent-name: $A"
grep -qx "Outsourcerer 0.16.2" <<<"$(eng hub export | jq -r '.projects[].name')" && ok "custom-title wins over a later ai-title; no 'Outsourcerer · Outsourcerer'" || bad "custom-title"
rm -f "$OSRC_HOME/hub/projects/$MC3_SID_A.json"
grep -qx "Total Recall · TR v1.8.6 build" <<<"$(eng hub export | jq -r '.projects[].name')" && ok "card with no --name: Project · last ai-title" || bad "ai-title card: $(eng hub export | jq -r '.projects[].name')"

echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" = 0 ]
