#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_remote_review.sh -- remote lanes (lib/remote.sh) + single-reviewer queue (lib/review.sh).
#
# No network: a local bare git repo stands in for the remote, a fake `tmux` stands in for the reviewer
# pane (its screens are REAL Claude Code captures in fixtures/review/), a fake `gh` stands in for
# GitHub's API. Time is a fake clock (OSRC_NOW, OSRC_TIME_UNIT=1) so "20 minutes" costs no sleeping.
# Every OSRC_HOME is under the runner's scratch directory; live state is never used.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"; FIX="$HERE/fixtures/review"
TMP="$(mktemp -d "${TMPDIR%/}/.test-remote-review.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
check() { # <desc> <command...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

export OSRC_HOME="$TMP/state" HOME="$TMP/home" CLAUDE_CODE_SESSION_ID="sess-test-l2"
mkdir -p "$OSRC_HOME" "$HOME" "$TMP/bin"
export OSRC_TIME_UNIT=1 OSRC_REMOTE_POLL_SECS=0 OSRC_SELF=osrc OSRC_REVIEW_SEND_PAUSE=0
export OSRC_NOW=1000000 OSRC_STOP_GUARD=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# ---- fake tmux: sessions are files in $FAKE_TMUX/<name>.screen ---------------------------------
export FAKE_TMUX="$TMP/tmux"; mkdir -p "$FAKE_TMUX"
cat > "$TMP/bin/tmux" <<'SH'
#!/usr/bin/env bash
d="$FAKE_TMUX"; sub="$1"; shift
tgt=""; lit=0; msg=""
while [ "$#" -gt 0 ]; do
  case "$1" in -t) tgt="${2#=}"; shift 2 ;; -p) shift ;; -l) lit=1; shift ;; --) shift; msg="$*"; break ;; *) key="$1"; shift ;; esac
done
case "$sub" in
  has-session) [ -f "$d/$tgt.screen" ] ;;
  capture-pane) [ -f "$d/$tgt.screen" ] && cat "$d/$tgt.screen" ;;
  send-keys)
    [ -f "$d/$tgt.screen" ] || exit 1
    if [ "$lit" = 1 ]; then printf 'LIT:%s\n' "$msg" >> "$d/$tgt.sent"; [ -f "$d/$tgt.eat" ] && printf '❯ %s\n' "$msg" >> "$d/$tgt.screen"
    elif [ "${key:-}" = Enter ]; then printf 'ENTER\n' >> "$d/$tgt.sent"; [ -f "$d/$tgt.eat" ] || { [ -f "$d/$tgt.working" ] && cp "$d/$tgt.working" "$d/$tgt.screen"; }; fi; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMP/bin/tmux"
# fake gh: replies from files so tests can script 401 / 403-rate-limit / success
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
[ -f "$GH_HANG" ] && sleep 3137
case "$*" in *"contents/"*) [ -f "$GH_CONTENTS_OK" ] && exit 0 || { echo "HTTP 404: Not Found" >&2; exit 1; } ;; esac
if [ -f "$GH_ERR" ]; then cat "$GH_ERR" >&2; exit 1; fi
cat "$GH_OUT"
SH
chmod +x "$TMP/bin/gh"
# counting git shim so we can prove "one network call per lane per poll"
REALGIT="$(command -v git)"
cat > "$TMP/bin/git" <<SH
#!/usr/bin/env bash
case "\$1" in ls-remote) echo ls-remote >> "$TMP/lsremote.count" ;; esac
exec "$REALGIT" "\$@"
SH
chmod +x "$TMP/bin/git"
export GH_LOG="$TMP/gh.log" GH_ERR="$TMP/gh.err" GH_OUT="$TMP/gh.out" GH_CONTENTS_OK="$TMP/gh.contents.ok" GH_HANG="$TMP/gh.hang"
export PATH="$TMP/bin:$PATH"

OSRC_SOURCED=1; export OSRC_SOURCED; set --; . "$SRC" >/dev/null 2>&1
for fn in cmd_lane cmd_review osrc_remote_state osrc_remote_events osrc_review_events delegate_grokbot; do
  type -t "$fn" >/dev/null || { echo "FAIL: $fn not loaded from lib/"; exit 1; }
done
ok "lib/remote.sh and lib/review.sh load when the script is sourced (and delegate_grokbot moved there still resolves)"

# ---- a bare "remote" and a working clone to push from -------------------------------------------
REMOTE="$TMP/remote.git"; WORK="$TMP/work"
git init -q --bare "$REMOTE"; git clone -q "$REMOTE" "$WORK" 2>/dev/null
( cd "$WORK" && git checkout -q -b main && echo base > f.txt && git add f.txt && git commit -q -m "base" && git push -q origin main )
push() { # <branch> <message> [file-to-add]   -> prints the new head
  ( cd "$WORK" && { git checkout -q "$1" 2>/dev/null || git checkout -q -b "$1" main; }
    echo "$RANDOM$RANDOM" > "c_$(printf '%s' "$1" | tr / _).$RANDOM"; [ -z "${3:-}" ] || echo ok > "$3"
    git add -A >/dev/null && git commit -q -m "$2" && git push -q origin "$1" 2>/dev/null && git rev-parse HEAD )
}
tick() { OSRC_NOW=$(( OSRC_NOW + $1 )); export OSRC_NOW; }
events() { osrc_remote_events 2>&1; }

# ---- 1. register + registry ---------------------------------------------------------------------
out="$(cmd_lane add cloud1 --branch cloud/v1 --repo "$REMOTE" 2>&1)"
grep -q 'lane cloud1 registered' <<<"$out" && ok "lane add registers a remote lane" || bad "lane add: $out"
[ -f "$OSRC_HOME/remote/cloud1.json" ] && ok "metadata written to remote/<id>.json" || bad "no lane json"
[ -f "$OSRC_HOME/owners/sess-test-l2/cloud1" ] && ok "lane recorded in the shared owner registry (_owner_record)" || bad "owner record missing"
[ "$(osrc_remote_state cloud1)" = live ] && ok "state before any push: live" || bad "state before push: $(osrc_remote_state cloud1)"
[ "$(osrc_remote_state nosuch)" = gone ] && ok "unknown lane: gone" || bad "unknown lane not gone"
( cmd_lane add cloud1 --branch x --repo "$REMOTE" ) >/dev/null 2>&1; [ $? -ne 0 ] && ok "duplicate lane id refused" || bad "duplicate accepted"
( cmd_lane add 'bad/id' --branch x --repo "$REMOTE" ) >/dev/null 2>&1; [ $? -ne 0 ] && ok "path-like lane id refused" || bad "bad id accepted"
( cmd_lane add b1 --branch 'x y' --repo "$REMOTE" ) >/dev/null 2>&1; [ $? -ne 0 ] && ok "branch with unpollable characters refused" || bad "bad branch accepted"
[ -z "$(events)" ] && ok "no event while nothing has been pushed" || bad "spurious event: $(events)"

# ---- 2. non-READY push is progress, not an event -----------------------------------------------
h1="$(push cloud/v1 "wip: scaffolding")"; tick 5
[ -z "$(events)" ] && ok "pushed but not READY: no event" || bad "event on non-READY push: $(events)"
[ "$(jq -r .head "$OSRC_HOME/remote/cloud1.json")" = "$h1" ] && [ "$(jq -r .head_ready "$OSRC_HOME/remote/cloud1.json")" = false ] \
  && ok "head tracked, head_ready=false" || bad "head tracking wrong"
[ "$(jq -r .last_push_ts "$OSRC_HOME/remote/cloud1.json")" = "$OSRC_NOW" ] && ok "progress refreshes the stall clock" || bad "last_push_ts not refreshed"
h1b="$(push cloud/v1 "this is not READY yet")"; tick 1
[ -z "$(events)" ] && [ "$(osrc_remote_state cloud1)" = live ] && ok '"not READY" in a message does not count as READY' || bad "'not READY' misread"

# ---- 3. READY push: event + auto-enqueue + dedupe ----------------------------------------------
h2="$(push cloud/v1 "READY: feature complete")"; tick 1
ev="$(events)"
grep -q "^EVENT done cloud1 $OSRC_NOW READY ${h2:0:7}" <<<"$ev" && ok "READY push emits EVENT done with sha7 and timestamp" || bad "no READY event: $ev"
grep -q '^NEXT osrc review reviewer <tmux-session>' <<<"$ev" && ok "with no reviewer the NEXT command tells you to set one" || bad "NEXT wrong: $ev"
[ -f "$OSRC_HOME/review/items/cloud1-${h2:0:7}.json" ] && ok "READY lane auto-enqueued (item cloud1-${h2:0:7})" || bad "not enqueued"
[ "$(osrc_remote_state cloud1)" = ready ] && ok "state: ready" || bad "state not ready: $(osrc_remote_state cloud1)"
[ -z "$(events | grep 'EVENT done cloud1')" ] && ok "the same READY head is not announced twice" || bad "READY event repeated"
cmd_review queue add cloud1 >/dev/null 2>&1; n=$(ls "$OSRC_HOME/review/items/" | wc -l | tr -d ' ')
[ "$n" = 1 ] && ok "manual add of the same lane+head dedupes (still 1 item)" || bad "duplicate item created ($n)"

# file-based READY marker
cmd_lane add cloud2 --branch cloud/v2 --repo "$REMOTE" >/dev/null
h3="$(push cloud/v2 "add parser" cloud2.READY)"; tick 1
events >/dev/null; [ -f "$OSRC_HOME/review/items/cloud2-${h3:0:7}.json" ] && ok "<id>.READY file at the tip counts as READY" || bad "file marker ignored"
# custom marker
cmd_lane add cloud6 --branch cloud/v6 --repo "$REMOTE" --ready SHIPPED >/dev/null
push cloud/v6 "READY but wrong marker" >/dev/null; tick 1; events >/dev/null
[ "$(osrc_remote_state cloud6)" = live ] && ok "--ready SHIPPED: a READY message does not trigger a SHIPPED lane" || bad "custom marker not honored"
h6="$(push cloud/v6 "SHIPPED the thing")"; tick 1; events >/dev/null
[ "$(osrc_remote_state cloud6)" = ready ] && ok "--ready SHIPPED: SHIPPED message triggers" || bad "custom marker message missed"

# ---- 4. reviewer: set, idle -> events + next -----------------------------------------------------
# This real pane is at 37%; raise the limit while testing ordinary queue flow.
export OSRC_REVIEW_CTX_MAX=40
cp "$FIX/cc-idle-composer-ctx37.txt" "$FAKE_TMUX/rv.screen"; cp "$FIX/cc-working-spinner.txt" "$FAKE_TMUX/rv.working"
( cmd_review next ) >/dev/null 2>&1; [ $? -eq 2 ] && ok "review next with no reviewer: rc 2, nothing sent" || bad "next without reviewer rc"
cmd_review reviewer rv >/dev/null 2>&1 && [ "$(cmd_review reviewer)" = rv ] && ok "review reviewer sets THE reviewer" || bad "reviewer not set"
tick 1; ev="$(events)"
grep -q '^EVENT idle rv .*3 queued' <<<"$ev" && grep -q '^NEXT osrc review next' <<<"$ev" && ok "reviewer idle + queue non-empty: EVENT idle, NEXT is review next" || bad "no reviewer-idle event: $ev"
[ "$(_osrc_review_screen rv)" = idle ] && ok "real Claude Code idle composer capture reads as idle" || bad "idle fixture misread: $(_osrc_review_screen rv)"
cp "$FIX/cc-working-spinner.txt" "$FAKE_TMUX/rv.screen"
[ "$(_osrc_review_screen rv)" = working ] && ok "real mid-turn spinner capture reads as working (not idle)" || bad "working fixture misread: $(_osrc_review_screen rv)"
cmd_review next >/dev/null 2>&1; rc=$?
[ "$rc" -eq 4 ] && [ ! -f "$FAKE_TMUX/rv.sent" ] && ok "review next refuses to type into a working reviewer (rc 4, nothing sent)" || bad "sent into busy reviewer rc=$rc"
cp "$FIX/cc-idle-composer-ctx37.txt" "$FAKE_TMUX/rv.screen"
out="$(cmd_review next 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && { _t3b_pipe="$(grep -c '^LIT:' "$FAKE_TMUX/rv.sent")" && grep -q '^1$' <<<"$_t3b_pipe"; } && ok "idle reviewer + queue: review next sends exactly one line" || bad "next did not send once rc=$rc out=$out"
first_item="$(jq -r 'select(.state=="inflight") | .id' "$OSRC_HOME"/review/items/*.json)"
grep -q "Review request $first_item: read $OSRC_HOME/review/$first_item.md" "$FAKE_TMUX/rv.sent" && grep -q "$first_item.VERDICT" "$FAKE_TMUX/rv.sent" \
  && ok "the instruction points at the brief file and names the VERDICT path" || bad "instruction text wrong: $(cat "$FAKE_TMUX/rv.sent")"
b="$OSRC_HOME/review/$first_item.md"
grep -q "$(jq -r .head "$OSRC_HOME/review/items/$first_item.json")" "$b" && grep -q 'git diff origin/main...FETCH_HEAD' "$b" && grep -qxF 'VERDICT: CHANGES must-fix=<n> nit=<n> pre-existing=<n>' "$b" \
  && ok "generated brief has branch, head sha, diff command and the verdict contract" || bad "brief incomplete"
cp "$FIX/cc-idle-composer-ctx37.txt" "$FAKE_TMUX/rv.screen"; : > "$FAKE_TMUX/rv.sent.keep"
cmd_review next >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && [ "$(grep -c '^LIT:' "$FAKE_TMUX/rv.sent")" = 1 ] && ok "never more than one in flight: second review next sends nothing (rc 3)" || bad "second send happened rc=$rc"
[ "$(jq -r '.reviews' "$OSRC_HOME/review/reviewer.json")" = 1 ] && ok "reviewer review count tracked for rotation" || bad "review count wrong"

# an Enter eaten by the pane is detected rather than reported as sent
cp "$FIX/cc-idle-composer-ctx37.txt" "$FAKE_TMUX/eat.screen"; touch "$FAKE_TMUX/eat.eat"
_osrc_review_send eat "hello reviewer line" ; [ $? -ne 0 ] && ok "text left sitting in the composer is reported as a failed send" || bad "eaten Enter reported as sent"

# ---- 5. idle without verdict (after the send grace) ---------------------------------------------
tick 10; ev="$(events)"
grep -q "EVENT idle rv .*without writing a verdict" <<<"$ev" && bad "idle-without-verdict fired inside the send grace" || ok "no idle-without-verdict inside the 45s send grace"
tick 60; ev="$(events)"
grep -q "^EVENT idle rv .*without writing a verdict for $first_item" <<<"$ev" && ok "reviewer idle past the grace with no verdict: EVENT idle" || bad "no stopped-reviewer event: $ev"
grep -q '^NEXT OUTSOURCERER_TMUX=rv osrc session read' <<<"$ev" && ok "NEXT reads the reviewer's session" || bad "stopped-reviewer NEXT wrong"

# ---- 6. verdict file -> done event, lane done ------------------------------------------------------
lane1="$(jq -r .lane "$OSRC_HOME/review/items/$first_item.json")"; head1="$(jq -r .head "$OSRC_HOME/review/items/$first_item.json")"
printf 'VERDICT: MERGE\nLooks fine, no findings.\n' > "$OSRC_HOME/review/$first_item.VERDICT"; tick 1
ev="$(events)"
grep -q "^EVENT done $lane1 [0-9]* VERDICT MERGE ${head1:0:7}" <<<"$ev" && ok "verdict file appears: EVENT done with the verdict in the detail" || bad "no verdict event: $ev"
it="$OSRC_HOME/review/items/$first_item.json"
[ "$(jq -r .verdict "$it")" = MERGE ] && [ "$(jq -r .sha_reviewed "$it")" = "$head1" ] && [ "$(jq -r .sha_at_ready "$it")" = "$head1" ] && [ "$(jq -r .findings "$it")" = "$OSRC_HOME/review/$first_item.VERDICT" ] \
  && ok "verdict contract: sha_at_ready, sha_reviewed, verdict, findings path recorded" || bad "verdict record incomplete: $(jq -c . "$it")"
[ "$(osrc_remote_state "$lane1")" = done ] && ok "MERGE verdict on the READY head: lane state done" || bad "lane state after MERGE: $(osrc_remote_state "$lane1")"
[ -z "$(git -C "$REMOTE" log --oneline main | grep -i merge)" ] && ok "nothing was merged automatically" || bad "something merged"

# ---- 7. push after verdict: stale + re-review ----------------------------------------------------
hfix="$(push cloud/v1 "READY: addressed review")"; tick 1; ev="$(events)"
[ "$(jq -r .stale "$it")" = true ] && [ "$(jq -r .stale_by "$it")" = "$hfix" ] && ok "a push after the verdict marks the old review STALE" || bad "old review not stale"
[ -f "$OSRC_HOME/review/items/$lane1-${hfix:0:7}.json" ] && [ "$(jq -r .rereview "$OSRC_HOME/review/items/$lane1-${hfix:0:7}.json")" = true ] && ok "re-review of the new head enqueued (flagged re-review)" || bad "no re-review item"
[ "$(osrc_remote_state "$lane1")" = ready ] && ok "stale MERGE no longer makes the lane done" || bad "stale verdict still counts"
ql="$(cmd_review queue ls)"; grep -q "STALE" <<<"$ql" && grep -q "re-review" <<<"$ql" && ok "queue ls shows STALE and re-review" || bad "queue ls missing stale marker"

# ---- 8. unreviewed after N minutes -------------------------------------------------------------------
tick 1300; ev="$(events)"
grep -q "^EVENT unreviewed " <<<"$ev" && ok "READY with no review started for OSRC_UNREVIEWED_MIN: EVENT unreviewed" || bad "no unreviewed event: $ev"
grep -q '^NEXT osrc review next' <<<"$ev" && ok "unreviewed NEXT is review next (reviewer set)" || bad "unreviewed NEXT wrong"

# ---- 9. stalled remote -----------------------------------------------------------------------------
cmd_lane add cloud3 --branch cloud/v3 --repo "$REMOTE" >/dev/null; push cloud/v3 "wip" >/dev/null; tick 1; events >/dev/null
tick 6000; ev="$(events)"
grep -q '^EVENT stalled cloud3 ' <<<"$ev" && ok "no push for OSRC_REMOTE_STALL minutes: EVENT stalled" || bad "no stalled event: $ev"
grep -q '^EVENT stalled cloud3 ' <<<"$(events)" && bad "stalled repeats immediately" || ok "stalled is throttled, not repeated each poll"
h3b="$(push cloud/v3 "back to work")"; tick 1; events >/dev/null
tick 50; grep -q '^EVENT stalled cloud3 ' <<<"$(events)" && bad "stalled right after a fresh push" || ok "a fresh push resets the stall clock"
# A lane that committed <id>.READY, then <id>.RESULT on top (tip subject "<id>: RESULT") is finished,
# not stalled. A RESULT with no READY in the tree still stalls.
cmd_lane add fin1 --branch cloud/fin1 --repo "$REMOTE" >/dev/null; cmd_lane add fin2 --branch cloud/fin2 --repo "$REMOTE" >/dev/null
push cloud/fin1 "fin1: conformance result, READY" fin1.READY >/dev/null; tick 1; events >/dev/null
hf1="$(push cloud/fin1 "fin1: RESULT" fin1.RESULT)"; push cloud/fin2 "fin2: RESULT" fin2.RESULT >/dev/null; tick 1; ev1="$(events)"
grep -q "^EVENT done fin1 .*READY ${hf1:0:7}" <<<"$ev1" && ok "a RESULT pushed after READY is READY at the new head: done event, queued for review" || bad "finished lane went silent: $ev1"
# Both commits between two polls: only the tip's files are read, the tree still shows both.
cmd_lane add fin3 --branch cloud/fin3 --repo "$REMOTE" >/dev/null; push cloud/fin3 "wip" >/dev/null; tick 1; events >/dev/null
push cloud/fin3 "fin3: READY" fin3.READY >/dev/null; hf3="$(push cloud/fin3 "fin3: RESULT" fin3.RESULT)"; tick 1
grep -q "^EVENT done fin3 .*READY ${hf3:0:7}" <<<"$(events)" && ok "READY and RESULT landing between two polls: READY at the tip" || bad "fin3 READY missed in one poll"
tick 6000; ev="$(events)"
grep -q '^EVENT stalled fin1 ' <<<"$ev" && bad "a lane whose tip carries its READY and RESULT was reported stalled: $ev" || ok "tip carrying <id>.READY and <id>.RESULT: finished, never stalled"
grep -q '^EVENT stalled fin2 ' <<<"$ev" && ok "a RESULT without a READY in the tree still stalls" || bad "fin2 not stalled: $ev"

# ---- 10. done-when check (runs in the background; events never wait for it) -------------------------------
waitrc() { local i; for i in $(seq 1 60); do [ -s "$1" ] && return 0; sleep 0.2; done; return 1; }
cmd_lane add cloud4 --branch cloud/v4 --repo "$REMOTE" --done-when 'check:test -f OK' >/dev/null
h4="$(push cloud/v4 "READY: first try")"; tick 1; ev="$(events)"
[ "$(osrc_remote_state cloud4)" = live ] || [ "$(osrc_remote_state cloud4)" = failed ]
ck="$(jq -r '.check.state' "$OSRC_HOME/remote/cloud4.json")"
{ [ "$ck" = running ] || [ "$ck" = done ]; } && ok "READY with --done-when: check is started in the background (state $ck)" || bad "check not started: $ck"
waitrc "$OSRC_HOME/remote/cloud4-${h4:0:7}.rc"; tick 1; ev="$(events)"
grep -q '^EVENT failed cloud4 .*done-when check failed' <<<"$ev" && ok "failing --done-when check: EVENT failed" || bad "no check-failed event: $ev"
[ ! -f "$OSRC_HOME/review/items/cloud4-${h4:0:7}.json" ] && ok "failed check: no review item, no review spent" || bad "review enqueued despite failed check"
[ "$(osrc_remote_state cloud4)" = failed ] && ok "lane state failed" || bad "state after failed check: $(osrc_remote_state cloud4)"
[ ! -d "$OSRC_HOME/remote/wt/cloud4-${h4:0:7}" ] && ok "the throwaway worktree is removed after the check" || bad "worktree left behind"
h4b="$(push cloud/v4 "READY: with OK" OK)"; tick 1; events >/dev/null; waitrc "$OSRC_HOME/remote/cloud4-${h4b:0:7}.rc"; tick 1; events >/dev/null
[ -f "$OSRC_HOME/review/items/cloud4-${h4b:0:7}.json" ] && [ "$(osrc_remote_state cloud4)" = ready ] && ok "passing check on the new READY sha: enqueued" || bad "passing check not enqueued"

# a slow check must not hold up osrc_remote_events (the contract says it never blocks)
cmd_lane add slowck --branch cloud/slowck --repo "$REMOTE" --done-when 'check:sleep 6; true' >/dev/null
hs="$(push cloud/slowck "READY: slow one")"; tick 1
t0=$SECONDS; ev="$(events)"; dt=$(( SECONDS - t0 ))
[ ! -s "$OSRC_HOME/remote/slowck-${hs:0:7}.rc" ] && ok "events returned (${dt}s) while the 6s check was still running in the background" || bad "events waited ${dt}s for the check"
[ "$(osrc_remote_state slowck)" = live ] && [ "$(jq -r '.check.state' "$OSRC_HOME/remote/slowck.json")" = running ] && [ ! -f "$OSRC_HOME/review/items/slowck-${hs:0:7}.json" ] \
  && ok "while the check runs: state live, check.state running, nothing enqueued yet" || bad "running-check state wrong: $(osrc_remote_state slowck)"
waitrc "$OSRC_HOME/remote/slowck-${hs:0:7}.rc"; tick 1; events >/dev/null
[ -f "$OSRC_HOME/review/items/slowck-${hs:0:7}.json" ] && [ "$(osrc_remote_state slowck)" = ready ] && ok "the finished check is collected on the next poll and enqueues" || bad "check result not collected"
# a runner that dies without writing a result is reported, not waited on forever
cmd_lane add deadrun --branch cloud/deadrun --repo "$REMOTE" --done-when 'check:true' >/dev/null
hd="$(push cloud/deadrun "wip")"; tick 1; events >/dev/null
jq --arg h "$hd" '.head=$h | .head_ready=true | .check={head:$h,state:"running",rc:null,ts:1,log:"",pid:999999,why:""}' "$OSRC_HOME/remote/deadrun.json" > "$TMP/x.json" && mv "$TMP/x.json" "$OSRC_HOME/remote/deadrun.json"
tick 1; ev="$(events)"
grep -q '^EVENT failed deadrun .*check runner died' <<<"$ev" && [ "$(osrc_remote_state deadrun)" = failed ] && ok "dead check runner: EVENT failed naming it" || bad "dead runner not reported: $ev"

# ---- 11. queued item superseded by a newer push -------------------------------------------------------
cmd_lane add cloud5 --branch cloud/v5 --repo "$REMOTE" >/dev/null
h5a="$(push cloud/v5 "READY a")"; tick 1; events >/dev/null; h5b="$(push cloud/v5 "READY b")"; tick 1; events >/dev/null
[ "$(jq -r .state "$OSRC_HOME/review/items/cloud5-${h5a:0:7}.json")" = superseded ] && [ "$(jq -r .state "$OSRC_HOME/review/items/cloud5-${h5b:0:7}.json")" = queued ] \
  && ok "queued review of an old sha is superseded by the new READY head" || bad "supersede failed"

# ---- 12. verdicts: CHANGES send-back, invalid first line ----------------------------------------------
cd "$TMP"
it2="$(jq -r 'select(.state=="queued") | .id' "$OSRC_HOME"/review/items/*.json | head -1)"; jq --arg i "$it2" '.state="inflight" | .sent_ts=1' "$OSRC_HOME/review/items/$it2.json" > "$TMP/x.json" && mv "$TMP/x.json" "$OSRC_HOME/review/items/$it2.json"
printf 'VERDICT: CHANGES must-fix=1 nit=0 pre-existing=0\n1. a.sh:10 missing quote\n' > "$OSRC_HOME/review/$it2.VERDICT"; tick 1; ev="$(events)"
grep -q "VERDICT CHANGES" <<<"$ev" && grep -q "^NEXT osrc review sendback $it2" <<<"$ev" && ok "CHANGES verdict: NEXT is review sendback" || bad "CHANGES NEXT wrong: $ev"
sb="$(cmd_review sendback "$it2")"; sha7="$(jq -r '.head[0:7]' "$OSRC_HOME/review/items/$it2.json")"
[ -f "$OSRC_HOME/review/REVIEW-$it2.md" ] && grep -q 'missing quote' "$OSRC_HOME/review/REVIEW-$it2.md" && grep -q 'relay this to lane' <<<"$sb" && ok "send-back writes REVIEW-<lane>-<sha7>.md and prints a relay message" || bad "send-back wrong: $sb"
it3="$(jq -r 'select(.state=="queued") | .id' "$OSRC_HOME"/review/items/*.json | head -1)"; jq '.state="inflight" | .sent_ts=1' "$OSRC_HOME/review/items/$it3.json" > "$TMP/x.json" && mv "$TMP/x.json" "$OSRC_HOME/review/items/$it3.json"
printf 'looks good to me\n' > "$OSRC_HOME/review/$it3.VERDICT"; tick 100; ev="$(OSRC_VERDICT_SETTLE_SECS=0 events)"
grep -q '^EVENT question ' <<<"$ev" && ok "verdict file without a stated VERDICT: first line: EVENT question (back to the reviewer)" || bad "invalid verdict not flagged: $ev"

cmd_review requeue "$it3" >/dev/null && [ "$(jq -r .state "$OSRC_HOME/review/items/$it3.json")" = queued ] && ok "review requeue returns a stuck in-flight item to the queue" || bad "requeue failed"
# ---- 13. rotation ----------------------------------------------------------------------------------------
unset OSRC_REVIEW_CTX_MAX
cp "$FIX/cc-idle-composer-ctx37.txt" "$FAKE_TMUX/rv.screen"
r="$(_osrc_review_rotation_due rv)"; grep -q 'context 37% (limit 35%)' <<<"$r" && ok "reviewer at 37% context rotates at the new 35% default" || bad "new context rotation default: '$r'"
cp "$FIX/cc-idle-composer-ctx56.txt" "$FAKE_TMUX/rv.screen"
r="$(OSRC_REVIEW_CTX_MAX=50 _osrc_review_rotation_due rv)"; grep -q 'context 56%' <<<"$r" && ok "context bar read from the real footer: 56% > 50 limit triggers rotation" || bad "ctx rotation: '$r'"
cp "$FIX/cc-idle-composer-ctx37.txt" "$FAKE_TMUX/rv.screen"
jq '.reviews=2' "$OSRC_HOME/review/reviewer.json" > "$TMP/x.json" && mv "$TMP/x.json" "$OSRC_HOME/review/reviewer.json"
r="$(_osrc_review_rotation_due rv)"; grep -q '2 reviews' <<<"$r" && ok "after K=2 reviews rotation is due" || bad "K rotation: '$r'"
q0=$(_osrc_review_count_queued)
cmd_review next >/dev/null 2>&1; rc=$?
[ "$rc" -eq 5 ] && ok "rotation due: review next refuses (rc 5) instead of overloading the reviewer" || bad "next ignored rotation rc=$rc (queued $q0)"
tick 200; ev="$(events)"; grep -q '^NEXT osrc review rotate' <<<"$ev" && ok "idle reviewer + rotation due: NEXT suggests a fresh reviewer" || bad "rotation NEXT missing: $ev"
{ _t3b_pipe="$(cmd_review rotate)" && grep -q 'review reviewer <new-session>' <<<"$_t3b_pipe"; } && ok "review rotate prints the 3 steps" || bad "rotate output"
cp "$FIX/cc-idle-composer-ctx37.txt" "$FAKE_TMUX/rv2.screen"
( cmd_review reviewer rv2 ) >/dev/null 2>&1; [ $? -ne 0 ] && [ "$(cmd_review reviewer)" = rv ] && ok "never two reviewers: switching while the old one is alive is refused" || bad "second reviewer accepted"
cmd_review reviewer rv2 --replace >/dev/null 2>&1 && [ "$(cmd_review reviewer)" = rv2 ] && [ "$(jq -r .reviews "$OSRC_HOME/review/reviewer.json")" = 0 ] && ok "--replace switches and resets the counters" || bad "replace failed"
rm -f "$FAKE_TMUX/rv2.screen"; tick 100; ev="$(events)"
grep -q '^EVENT failed rv2 .*gone' <<<"$ev" && ok "reviewer session gone with work queued: EVENT failed" || bad "dead reviewer not reported: $ev"

# ---- 14. gh transport (fake gh): auth, rate limit, success ----------------------------------------------
cmd_lane add ghlane --branch cloud/gh1 --repo octo/widgets >/dev/null 2>&1
printf 'gh: To use GitHub CLI in a script, authenticate with gh auth login (HTTP 401)\n' > "$GH_ERR"; tick 1; ev="$(events)"
grep -q '^EVENT failed ghlane .*auth failure' <<<"$ev" && grep -q '^NEXT gh auth status' <<<"$ev" && ok "gh auth failure: EVENT failed with the reason, not silence" || bad "no auth failure event: $ev"
printf 'gh: API rate limit exceeded for user (HTTP 403)\n' > "$GH_ERR"; tick 2000; ev="$(events)"
grep -q '^EVENT failed ghlane .*rate limited' <<<"$ev" && ok "gh rate limit: EVENT failed naming the rate limit" || bad "no rate-limit event: $ev"
rm -f "$GH_ERR"
jq -n '{sha:"aaaaaaa1111111111111111111111111111111aa", commit:{message:"READY: gh lane done"}, files:[{filename:"x.txt"}]}' > "$GH_OUT"
tick 2000; ev="$(events)"
grep -q '^EVENT done ghlane .*READY aaaaaaa' <<<"$ev" && ok "gh transport: READY detected from one commits API call" || bad "gh READY missed: $ev"
[ "$(jq -r .err_count "$OSRC_HOME/remote/ghlane.json")" = 0 ] && ok "a good poll clears the error state" || bad "error state stuck"
jq -n '{sha:"bbbbbbb2222222222222222222222222222222bb", commit:{message:"more work"}, files:[]}' > "$GH_OUT"; : > "$GH_CONTENTS_OK"; tick 5; events >/dev/null
[ "$(jq -r .head_ready "$OSRC_HOME/remote/ghlane.json")" = false ] && ! grep -q 'contents/' "$GH_LOG" && ok "gh transport: a READY file from an EARLIER commit does not make a later push READY (no contents calls either)" || bad "gh sticky READY"
rm -f "$GH_CONTENTS_OK"

# ---- 15. polling is rate limited: one ls-remote per lane per OSRC_REMOTE_POLL_SECS ------------------------------
cmd_lane add rl --branch cloud/rl --repo "$REMOTE" >/dev/null; : > "$TMP/lsremote.count"
( export OSRC_REMOTE_POLL_SECS=60; tick 61; for i in 1 2 3 4; do _osrc_lane_poll rl; done; tick 61; _osrc_lane_poll rl )
[ "$(wc -l < "$TMP/lsremote.count" | tr -d ' ')" = 2 ] && ok "4 polls inside one 60s window cost 1 ls-remote; 61s later one more (not one per call)" || bad "poll rate limit: $(wc -l < "$TMP/lsremote.count") ls-remote calls"

# ---- 16. deleted branch, rm, stop-guard registry ---------------------------------------------------------------------
cmd_lane add del --branch cloud/del --repo "$REMOTE" >/dev/null; push cloud/del "wip" >/dev/null; tick 1; events >/dev/null
git -C "$REMOTE" branch -q -D cloud/del; tick 1; ev="$(events)"
grep -q '^EVENT failed del .*deleted' <<<"$ev" && [ "$(osrc_remote_state del)" = failed ] && ok "branch deleted after being seen: EVENT failed, state failed" || bad "deleted branch: $ev"
cmd_lane rm del >/dev/null && [ ! -f "$OSRC_HOME/remote/del.json" ] && [ ! -f "$OSRC_HOME/owners/sess-test-l2/del" ] && [ "$(osrc_remote_state del)" = gone ] && ok "lane rm removes metadata and the owner record" || bad "lane rm incomplete"
ll="$(cmd_lane ls)"; grep -q 'cloud1' <<<"$ll" && ok "lane ls lists lanes" || bad "lane ls"


# ---- 18. finding 1: lane rm then lane add must not lose a READY head -----------------------------------------------
cmd_lane add dd --branch cloud/dd --repo "$REMOTE" >/dev/null; hdd="$(push cloud/dd "READY: first")"; tick 1; events >/dev/null
[ -f "$OSRC_HOME/review/items/dd-${hdd:0:7}.json" ] || bad "setup: dd not enqueued"
cmd_lane rm dd >/dev/null
[ ! -d "$OSRC_HOME/remote/.ev/dd" ] && [ ! -f "$OSRC_HOME/review/items/dd-${hdd:0:7}.json" ] && ok "lane rm clears the lane's event stamps and its review items" || bad "lane rm left stamps/items"
cmd_lane add dd --branch cloud/dd --repo "$REMOTE" >/dev/null; tick 1; ev="$(events)"
grep -q "^EVENT done dd .*READY ${hdd:0:7}" <<<"$ev" && [ -f "$OSRC_HOME/review/items/dd-${hdd:0:7}.json" ] && ok "lane re-added under the same id: READY announced again and queued" || bad "re-added lane lost its READY head: $ev"
cmd_review drop "dd-${hdd:0:7}" >/dev/null; tick 1000; ev="$(events)"
grep -q "^EVENT unreviewed dd .*no review item" <<<"$ev" && grep -q "^NEXT osrc review requeue dd-${hdd:0:7}" <<<"$ev" && ok "backstop: a READY lane with no live item raises EVENT unreviewed with the fix as NEXT" || bad "backstop missing: $ev"

# ---- 19. finding 2: a lane sent CHANGES gets a stall clock -------------------------------------------------------
cmd_lane add chg --branch cloud/chg --repo "$REMOTE" >/dev/null; hc="$(push cloud/chg "READY: v1")"; tick 1; events >/dev/null
jq '.state="inflight" | .sent_ts=1' "$OSRC_HOME/review/items/chg-${hc:0:7}.json" > "$TMP/x.json" && mv "$TMP/x.json" "$OSRC_HOME/review/items/chg-${hc:0:7}.json"
printf 'VERDICT: CHANGES must-fix=1 nit=0 pre-existing=0\n1. fix it\n' > "$OSRC_HOME/review/chg-${hc:0:7}.VERDICT"; tick 1; events >/dev/null
[ "$(osrc_remote_state chg)" = live ] && ok "READY head with a CHANGES verdict: lane is live (the ball is back with it)" || bad "CHANGES state: $(osrc_remote_state chg)"
cmd_review ack "chg-${hc:0:7}" >/dev/null; tick 6000; ev="$(events)"
grep -q '^EVENT stalled chg ' <<<"$ev" && ok "CHANGES then silence past OSRC_REMOTE_STALL: EVENT stalled (clock starts at the verdict)" || bad "no stall after CHANGES: $ev"

# ---- 20. finding 3: a READY file is not sticky ----------------------------------------------------------------------
cmd_lane add fl --branch cloud/fl --repo "$REMOTE" >/dev/null; hf1="$(push cloud/fl "add feature" fl.READY)"; tick 1; events >/dev/null
[ "$(osrc_remote_state fl)" = ready ] && ok "tip commit adds fl.READY: READY" || bad "file marker not seen: $(osrc_remote_state fl)"
n0=$(ls "$OSRC_HOME/review/items" | grep -c '^fl-')
hf2="$(push cloud/fl "wip: half way through the review fixes")"; tick 1; events >/dev/null
n1=$(ls "$OSRC_HOME/review/items" | grep -c '^fl-')
{ ls "$WORK" >/dev/null; { _t3b_pipe="$(git -C "$REMOTE" ls-tree --name-only "$hf2")" && grep -qx 'fl.READY' <<<"$_t3b_pipe"; }; } && [ "$(jq -r .head_ready "$OSRC_HOME/remote/fl.json")" = false ] && [ "$n0" = "$n1" ] && [ "$(osrc_remote_state fl)" != ready ] \
  && ok "a later WIP push with fl.READY still in the tree is NOT READY and spends no review" || bad "sticky READY file: ready=$(jq -r .head_ready "$OSRC_HOME/remote/fl.json") items $n0->$n1"

# ---- 21. finding 5: a hung network call is bounded ---------------------------------------------------------------
cmd_lane add hang --branch cloud/hang --repo octo/hang >/dev/null 2>&1; : > "$GH_HANG"; rm -f "$GH_ERR"
t0=$SECONDS; ( export OSRC_NET_TIMEOUT=1; _osrc_lane_poll hang force ); dt=$(( SECONDS - t0 ))
[ "$dt" -le 4 ] && [ "$(jq -r .err_count "$OSRC_HOME/remote/hang.json")" -ge 1 ] && { _t3b_pipe="$(jq -r .err_msg "$OSRC_HOME/remote/hang.json")" && grep -q 'timed out' <<<"$_t3b_pipe"; } \
  && ok "hung gh call is killed at OSRC_NET_TIMEOUT (${dt}s) and recorded as a poll error" || bad "hung call not bounded: ${dt}s $(jq -c '[.err_count,.err_msg]' "$OSRC_HOME/remote/hang.json")"
rm -f "$GH_HANG"; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f 'sleep 31[3]7' >/dev/null || break; sleep 0.3; done   # orphaned child is reaped by init asynchronously
pgrep -f 'sleep 31[3]7' >/dev/null && bad "hung child left running" || ok "the hung child process group is gone"

# ---- 22. finding 6: composer with unsent text is not idle (L3's reader stubbed) ---------------------------------------------
export STUB_SCR="$TMP/stub.scr"
osrc_screen_state() { cat "$STUB_SCR"; }
printf 'composer\ncomposer holds unsent text: half a thought\n' > "$STUB_SCR"
[ "$(_osrc_review_screen rv2)" = unknown ] && ok "L3 'composer holds unsent text' reads as unknown, not idle" || bad "unsent composer read as $(_osrc_review_screen rv2)"
printf 'composer\ncomposer ready, no turn yet\n' > "$STUB_SCR"
[ "$(_osrc_review_screen rv2)" = idle ] && ok "L3 'composer ready, no turn yet' (fresh reviewer) is idle" || bad "fresh composer read as $(_osrc_review_screen rv2)"
printf 'idle\ncomposer ready after: done\n' > "$STUB_SCR"; [ "$(_osrc_review_screen rv2)" = idle ] && ok "L3 idle is idle" || bad "L3 idle misread"
printf 'question\nprose question\n' > "$STUB_SCR"; [ "$(_osrc_review_screen rv2)" = approval ] && ok "L3 question is held (approval class), never sent into" || bad "question misread"
cp "$FIX/cc-idle-composer-ctx37.txt" "$FAKE_TMUX/rv2.screen"; rm -f "$FAKE_TMUX/rv2.sent"
printf 'composer\ncomposer holds unsent text: half a thought\n' > "$STUB_SCR"
jq -n '{session:"rv2",since_ts:1,reviews:0}' > "$OSRC_HOME/review/reviewer.json"
cmd_lane add nx --branch cloud/nx --repo "$REMOTE" >/dev/null; push cloud/nx "READY: nx" >/dev/null; tick 1; events >/dev/null
cmd_review next >/dev/null 2>&1; rc=$?
[ "$rc" -eq 4 ] && [ ! -f "$FAKE_TMUX/rv2.sent" ] && ok "review next types nothing onto unsent composer text (rc 4)" || bad "typed onto unsent text rc=$rc"
unset -f osrc_screen_state

# ---- 23. finding 7: one marker rule (subject line, start or end, not negated) ----------------------------------------------
mr() { _osrc_msg_ready "$1" READY && echo yes || echo no; }
[ "$(mr 'READY. Known gap: docs are not ready yet')" = yes ] && [ "$(mr 'READY for review; unready paths removed')" = yes ] && [ "$(mr 'fix the tests READY')" = yes ] \
  && ok "READY at the start/end of the subject counts even when the text later says 'not ready'" || bad "marker rule: positive cases"
[ "$(mr 'docs: explain the READY marker')" = no ] && [ "$(mr 'wip: not READY, tests red')" = no ] && [ "$(mr 'this is not READY')" = no ] && [ "$(mr "$(printf 'wip\n\nREADY in the body')")" = no ] \
  && ok "mid-subject mentions, 'not READY' and body-only READY do not count" || bad "marker rule: negative cases"

# ---- 24. finding 8: requeue of an in-flight item is refused while the reviewer may be on it -------------------------------------
cp "$FIX/cc-working-spinner.txt" "$FAKE_TMUX/rv2.screen"
inf="$(ls "$OSRC_HOME/review/items" | head -1 | sed 's/\.json$//')"
jq '.state="inflight" | .sent_ts=$ENV.OSRC_NOW' "$OSRC_HOME/review/items/$inf.json" > "$TMP/x.json" 2>/dev/null || jq --argjson n "$OSRC_NOW" '.state="inflight" | .sent_ts=$n' "$OSRC_HOME/review/items/$inf.json" > "$TMP/x.json"
mv "$TMP/x.json" "$OSRC_HOME/review/items/$inf.json"
( cmd_review requeue "$inf" ) >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .state "$OSRC_HOME/review/items/$inf.json")" = inflight ] && ok "requeue of an in-flight item with a working reviewer is refused" || bad "requeue allowed while working rc=$rc"
cmd_review requeue "$inf" --force >/dev/null 2>&1 && [ "$(jq -r .state "$OSRC_HOME/review/items/$inf.json")" = queued ] && ok "requeue --force overrides" || bad "--force requeue failed"

# ---- 25. finding 9: prefix mix-ups ------------------------------------------------------------------------------------
cmd_lane add xx --branch cloud/xx --repo "$REMOTE" >/dev/null; mkdir -p "$OSRC_HOME/remote/wt/xx-yy-abc1234" "$OSRC_HOME/remote/wt/xx-abc1234"
cmd_lane rm xx >/dev/null
[ -d "$OSRC_HOME/remote/wt/xx-yy-abc1234" ] && [ ! -d "$OSRC_HOME/remote/wt/xx-abc1234" ] && ok "lane rm xx removes xx's scratch worktree and leaves lane xx-yy's alone" || bad "lane rm glob mix-up"
jq -n '{id:"L2-remote-abc1234",lane:"L2-remote",head:"abc1234abc1234abc1234abc1234abc1234abc12",state:"queued",enq_ts:1}' > "$OSRC_HOME/review/items/L2-remote-abc1234.json"
_osrc_review_item_exists_for_lane L2 && bad "lane L2 matched items of L2-remote" || ok "item lookup matches the lane exactly, not a name prefix"

# ---- 17. the CLI works end-to-end through a PATH symlink (the loader finds lib/ via BASH_SOURCE) ------------------------------
mkdir -p "$TMP/linkbin"; ln -s "$SRC" "$TMP/linkbin/outsourcerer"
out="$(OSRC_SOURCED= PATH="$TMP/linkbin:$PATH" outsourcerer lane ls 2>&1)"; grep -q 'LANE' <<<"$out" && ok "lane via a PATH launcher symlink" || bad "symlink launch: $out"
out="$(OSRC_SOURCED= PATH="$TMP/linkbin:$PATH" outsourcerer review queue ls 2>&1)"; grep -q 'reviewer:' <<<"$out" && ok "review via a PATH launcher symlink" || bad "symlink review: $out"

echo "---- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
