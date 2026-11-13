#!/usr/bin/env bash
# test_remote_review.sh -- remote lanes (lib/remote.sh) + single-reviewer queue (lib/review.sh).
#
# No network: a local bare git repo stands in for the remote, a fake `tmux` stands in for the reviewer
# pane (its screens are REAL Claude Code captures in fixtures/review/), a fake `gh` stands in for
# GitHub's API. Time is a fake clock (OSRC_NOW, OSRC_TIME_UNIT=1) so "20 minutes" costs no sleeping.
# Every OSRC_HOME is a scratch dir under this folder; nothing touches ~/.outsourcerer.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"; FIX="$HERE/fixtures/review"
TMP="$(mktemp -d "$HERE/.test-remote-review.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
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
export GH_LOG="$TMP/gh.log" GH_ERR="$TMP/gh.err" GH_OUT="$TMP/gh.out" GH_CONTENTS_OK="$TMP/gh.contents.ok"
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
echo "$out" | grep -q 'lane cloud1 registered' && ok "lane add registers a remote lane" || bad "lane add: $out"
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
echo "$ev" | grep -q "^EVENT done cloud1 $OSRC_NOW READY ${h2:0:7}" && ok "READY push emits EVENT done with sha7 and timestamp" || bad "no READY event: $ev"
echo "$ev" | grep -q '^NEXT osrc review reviewer <tmux-session>' && ok "with no reviewer the NEXT command tells you to set one" || bad "NEXT wrong: $ev"
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
cp "$FIX/cc-idle-composer-ctx37.txt" "$FAKE_TMUX/rv.screen"; cp "$FIX/cc-working-spinner.txt" "$FAKE_TMUX/rv.working"
( cmd_review next ) >/dev/null 2>&1; [ $? -eq 2 ] && ok "review next with no reviewer: rc 2, nothing sent" || bad "next without reviewer rc"
cmd_review reviewer rv >/dev/null 2>&1 && [ "$(cmd_review reviewer)" = rv ] && ok "review reviewer sets THE reviewer" || bad "reviewer not set"
tick 1; ev="$(events)"
echo "$ev" | grep -q '^EVENT idle rv .*3 queued' && echo "$ev" | grep -q '^NEXT osrc review next' && ok "reviewer idle + queue non-empty: EVENT idle, NEXT is review next" || bad "no reviewer-idle event: $ev"
[ "$(_osrc_review_screen rv)" = idle ] && ok "real Claude Code idle composer capture reads as idle" || bad "idle fixture misread: $(_osrc_review_screen rv)"
cp "$FIX/cc-working-spinner.txt" "$FAKE_TMUX/rv.screen"
[ "$(_osrc_review_screen rv)" = working ] && ok "real mid-turn spinner capture reads as working (not idle)" || bad "working fixture misread: $(_osrc_review_screen rv)"
cmd_review next >/dev/null 2>&1; rc=$?
[ "$rc" -eq 4 ] && [ ! -f "$FAKE_TMUX/rv.sent" ] && ok "review next refuses to type into a working reviewer (rc 4, nothing sent)" || bad "sent into busy reviewer rc=$rc"
cp "$FIX/cc-idle-composer-ctx37.txt" "$FAKE_TMUX/rv.screen"
out="$(cmd_review next 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -c '^LIT:' "$FAKE_TMUX/rv.sent" | grep -q '^1$' && ok "idle reviewer + queue: review next sends exactly one line" || bad "next did not send once rc=$rc out=$out"
first_item="$(jq -r 'select(.state=="inflight") | .id' "$OSRC_HOME"/review/items/*.json)"
grep -q "Review request $first_item: read $OSRC_HOME/review/$first_item.md" "$FAKE_TMUX/rv.sent" && grep -q "$first_item.VERDICT" "$FAKE_TMUX/rv.sent" \
  && ok "the instruction points at the brief file and names the VERDICT path" || bad "instruction text wrong: $(cat "$FAKE_TMUX/rv.sent")"
b="$OSRC_HOME/review/$first_item.md"
grep -q "$(jq -r .head "$OSRC_HOME/review/items/$first_item.json")" "$b" && grep -q 'git diff origin/main...FETCH_HEAD' "$b" && grep -q 'MERGE, CHANGES or BLOCK' "$b" \
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
echo "$ev" | grep -q "EVENT idle rv .*without writing a verdict" && bad "idle-without-verdict fired inside the send grace" || ok "no idle-without-verdict inside the 45s send grace"
tick 60; ev="$(events)"
echo "$ev" | grep -q "^EVENT idle rv .*without writing a verdict for $first_item" && ok "reviewer idle past the grace with no verdict: EVENT idle" || bad "no stopped-reviewer event: $ev"
echo "$ev" | grep -q '^NEXT OUTSOURCERER_TMUX=rv osrc session read' && ok "NEXT reads the reviewer's session" || bad "stopped-reviewer NEXT wrong"

# ---- 6. verdict file -> done event, lane done ------------------------------------------------------
lane1="$(jq -r .lane "$OSRC_HOME/review/items/$first_item.json")"; head1="$(jq -r .head "$OSRC_HOME/review/items/$first_item.json")"
printf 'MERGE\nLooks fine, no findings.\n' > "$OSRC_HOME/review/$first_item.VERDICT"; tick 1
ev="$(events)"
echo "$ev" | grep -q "^EVENT done $lane1 [0-9]* VERDICT MERGE ${head1:0:7}" && ok "verdict file appears: EVENT done with the verdict in the detail" || bad "no verdict event: $ev"
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
ql="$(cmd_review queue ls)"; echo "$ql" | grep -q "STALE" && echo "$ql" | grep -q "re-review" && ok "queue ls shows STALE and re-review" || bad "queue ls missing stale marker"

# ---- 8. unreviewed after N minutes -------------------------------------------------------------------
tick 1300; ev="$(events)"
echo "$ev" | grep -q "^EVENT unreviewed " && ok "READY with no review started for OSRC_UNREVIEWED_MIN: EVENT unreviewed" || bad "no unreviewed event: $ev"
echo "$ev" | grep -q '^NEXT osrc review next' && ok "unreviewed NEXT is review next (reviewer set)" || bad "unreviewed NEXT wrong"

# ---- 9. stalled remote -----------------------------------------------------------------------------
cmd_lane add cloud3 --branch cloud/v3 --repo "$REMOTE" >/dev/null; push cloud/v3 "wip" >/dev/null; tick 1; events >/dev/null
tick 6000; ev="$(events)"
echo "$ev" | grep -q '^EVENT stalled cloud3 ' && ok "no push for OSRC_REMOTE_STALL minutes: EVENT stalled" || bad "no stalled event: $ev"
echo "$(events)" | grep -q '^EVENT stalled cloud3 ' && bad "stalled repeats immediately" || ok "stalled is throttled, not repeated each poll"
h3b="$(push cloud/v3 "back to work")"; tick 1; events >/dev/null
tick 50; echo "$(events)" | grep -q '^EVENT stalled cloud3 ' && bad "stalled right after a fresh push" || ok "a fresh push resets the stall clock"

# ---- 10. done-when check ---------------------------------------------------------------------------
cmd_lane add cloud4 --branch cloud/v4 --repo "$REMOTE" --done-when 'check:test -f OK' >/dev/null
h4="$(push cloud/v4 "READY: first try")"; tick 1; ev="$(events)"
echo "$ev" | grep -q '^EVENT failed cloud4 .*done-when check failed' && ok "failing --done-when check: EVENT failed" || bad "no check-failed event: $ev"
[ ! -f "$OSRC_HOME/review/items/cloud4-${h4:0:7}.json" ] && ok "failed check: no review item, no review spent" || bad "review enqueued despite failed check"
[ "$(osrc_remote_state cloud4)" = failed ] && ok "lane state failed" || bad "state after failed check: $(osrc_remote_state cloud4)"
[ ! -d "$OSRC_HOME/remote/wt/cloud4-${h4:0:7}" ] && ok "the throwaway worktree is removed after the check" || bad "worktree left behind"
h4b="$(push cloud/v4 "READY: with OK" OK)"; tick 1; events >/dev/null
[ -f "$OSRC_HOME/review/items/cloud4-${h4b:0:7}.json" ] && [ "$(osrc_remote_state cloud4)" = ready ] && ok "passing check on the new READY sha: enqueued" || bad "passing check not enqueued"

# ---- 11. queued item superseded by a newer push -------------------------------------------------------
cmd_lane add cloud5 --branch cloud/v5 --repo "$REMOTE" >/dev/null
h5a="$(push cloud/v5 "READY a")"; tick 1; events >/dev/null; h5b="$(push cloud/v5 "READY b")"; tick 1; events >/dev/null
[ "$(jq -r .state "$OSRC_HOME/review/items/cloud5-${h5a:0:7}.json")" = superseded ] && [ "$(jq -r .state "$OSRC_HOME/review/items/cloud5-${h5b:0:7}.json")" = queued ] \
  && ok "queued review of an old sha is superseded by the new READY head" || bad "supersede failed"

# ---- 12. verdicts: CHANGES send-back, invalid first line ----------------------------------------------
cd "$TMP"
it2="$(jq -r 'select(.state=="queued") | .id' "$OSRC_HOME"/review/items/*.json | head -1)"; jq --arg i "$it2" '.state="inflight" | .sent_ts=1' "$OSRC_HOME/review/items/$it2.json" > "$TMP/x.json" && mv "$TMP/x.json" "$OSRC_HOME/review/items/$it2.json"
printf 'CHANGES\n1. a.sh:10 missing quote\n' > "$OSRC_HOME/review/$it2.VERDICT"; tick 1; ev="$(events)"
echo "$ev" | grep -q "VERDICT CHANGES" && echo "$ev" | grep -q "^NEXT osrc review sendback $it2" && ok "CHANGES verdict: NEXT is review sendback" || bad "CHANGES NEXT wrong: $ev"
sb="$(cmd_review sendback "$it2")"; sha7="$(jq -r '.head[0:7]' "$OSRC_HOME/review/items/$it2.json")"
[ -f "$OSRC_HOME/review/REVIEW-$sha7.md" ] && grep -q 'missing quote' "$OSRC_HOME/review/REVIEW-$sha7.md" && echo "$sb" | grep -q 'relay this to lane' && ok "send-back writes REVIEW-<sha7>.md and prints a relay message" || bad "send-back wrong: $sb"
it3="$(jq -r 'select(.state=="queued") | .id' "$OSRC_HOME"/review/items/*.json | head -1)"; jq '.state="inflight" | .sent_ts=1' "$OSRC_HOME/review/items/$it3.json" > "$TMP/x.json" && mv "$TMP/x.json" "$OSRC_HOME/review/items/$it3.json"
printf 'looks good to me\n' > "$OSRC_HOME/review/$it3.VERDICT"; tick 100; ev="$(OSRC_VERDICT_SETTLE_SECS=0 events)"
echo "$ev" | grep -q '^EVENT question ' && ok "verdict file without MERGE/CHANGES/BLOCK first line: EVENT question" || bad "invalid verdict not flagged: $ev"

cmd_review requeue "$it3" >/dev/null && [ "$(jq -r .state "$OSRC_HOME/review/items/$it3.json")" = queued ] && ok "review requeue returns a stuck in-flight item to the queue" || bad "requeue failed"
# ---- 13. rotation ----------------------------------------------------------------------------------------
cp "$FIX/cc-idle-composer-ctx37.txt" "$FAKE_TMUX/rv.screen"
[ -z "$(_osrc_review_rotation_due rv)" ] && ok "fresh reviewer at 37% context: no rotation" || bad "premature rotation"
cp "$FIX/cc-idle-composer-ctx56.txt" "$FAKE_TMUX/rv.screen"
r="$(OSRC_REVIEW_CTX_MAX=50 _osrc_review_rotation_due rv)"; echo "$r" | grep -q 'context 56%' && ok "context bar read from the real footer: 56% > 50 limit triggers rotation" || bad "ctx rotation: '$r'"
cp "$FIX/cc-idle-composer-ctx37.txt" "$FAKE_TMUX/rv.screen"
jq '.reviews=6' "$OSRC_HOME/review/reviewer.json" > "$TMP/x.json" && mv "$TMP/x.json" "$OSRC_HOME/review/reviewer.json"
r="$(_osrc_review_rotation_due rv)"; echo "$r" | grep -q '6 reviews' && ok "after K=6 reviews rotation is due" || bad "K rotation: '$r'"
q0=$(_osrc_review_count_queued)
cmd_review next >/dev/null 2>&1; rc=$?
[ "$rc" -eq 5 ] && ok "rotation due: review next refuses (rc 5) instead of overloading the reviewer" || bad "next ignored rotation rc=$rc (queued $q0)"
tick 200; ev="$(events)"; echo "$ev" | grep -q '^NEXT osrc review rotate' && ok "idle reviewer + rotation due: NEXT suggests a fresh reviewer" || bad "rotation NEXT missing: $ev"
cmd_review rotate | grep -q 'review reviewer <new-session>' && ok "review rotate prints the 3 steps" || bad "rotate output"
cp "$FIX/cc-idle-composer-ctx37.txt" "$FAKE_TMUX/rv2.screen"
( cmd_review reviewer rv2 ) >/dev/null 2>&1; [ $? -ne 0 ] && [ "$(cmd_review reviewer)" = rv ] && ok "never two reviewers: switching while the old one is alive is refused" || bad "second reviewer accepted"
cmd_review reviewer rv2 --replace >/dev/null 2>&1 && [ "$(cmd_review reviewer)" = rv2 ] && [ "$(jq -r .reviews "$OSRC_HOME/review/reviewer.json")" = 0 ] && ok "--replace switches and resets the counters" || bad "replace failed"
rm -f "$FAKE_TMUX/rv2.screen"; tick 100; ev="$(events)"
echo "$ev" | grep -q '^EVENT failed rv2 .*gone' && ok "reviewer session gone with work queued: EVENT failed" || bad "dead reviewer not reported: $ev"

# ---- 14. gh transport (fake gh): auth, rate limit, success ----------------------------------------------
cmd_lane add ghlane --branch cloud/gh1 --repo octo/widgets >/dev/null 2>&1
printf 'gh: To use GitHub CLI in a script, authenticate with gh auth login (HTTP 401)\n' > "$GH_ERR"; tick 1; ev="$(events)"
echo "$ev" | grep -q '^EVENT failed ghlane .*auth failure' && echo "$ev" | grep -q '^NEXT gh auth status' && ok "gh auth failure: EVENT failed with the reason, not silence" || bad "no auth failure event: $ev"
printf 'gh: API rate limit exceeded for user (HTTP 403)\n' > "$GH_ERR"; tick 2000; ev="$(events)"
echo "$ev" | grep -q '^EVENT failed ghlane .*rate limited' && ok "gh rate limit: EVENT failed naming the rate limit" || bad "no rate-limit event: $ev"
rm -f "$GH_ERR"
jq -n '{sha:"aaaaaaa1111111111111111111111111111111aa", commit:{message:"READY: gh lane done"}, files:[{filename:"x.txt"}]}' > "$GH_OUT"
tick 2000; ev="$(events)"
echo "$ev" | grep -q '^EVENT done ghlane .*READY aaaaaaa' && ok "gh transport: READY detected from one commits API call" || bad "gh READY missed: $ev"
[ "$(jq -r .err_count "$OSRC_HOME/remote/ghlane.json")" = 0 ] && ok "a good poll clears the error state" || bad "error state stuck"
jq -n '{sha:"bbbbbbb2222222222222222222222222222222bb", commit:{message:"more work"}, files:[]}' > "$GH_OUT"; : > "$GH_CONTENTS_OK"; tick 5; events >/dev/null
[ "$(jq -r .head_ready "$OSRC_HOME/remote/ghlane.json")" = true ] && ok "gh transport: READY file left in the tree is found with contents API when the tip commit did not touch it" || bad "gh contents READY missed"
rm -f "$GH_CONTENTS_OK"

# ---- 15. polling is rate limited: one ls-remote per lane per OSRC_REMOTE_POLL_SECS ------------------------------
cmd_lane add rl --branch cloud/rl --repo "$REMOTE" >/dev/null; : > "$TMP/lsremote.count"
( export OSRC_REMOTE_POLL_SECS=60; tick 61; for i in 1 2 3 4; do _osrc_lane_poll rl; done; tick 61; _osrc_lane_poll rl )
[ "$(wc -l < "$TMP/lsremote.count" | tr -d ' ')" = 2 ] && ok "4 polls inside one 60s window cost 1 ls-remote; 61s later one more (not one per call)" || bad "poll rate limit: $(wc -l < "$TMP/lsremote.count") ls-remote calls"

# ---- 16. deleted branch, rm, stop-guard registry ---------------------------------------------------------------------
cmd_lane add del --branch cloud/del --repo "$REMOTE" >/dev/null; push cloud/del "wip" >/dev/null; tick 1; events >/dev/null
git -C "$REMOTE" branch -q -D cloud/del; tick 1; ev="$(events)"
echo "$ev" | grep -q '^EVENT failed del .*deleted' && [ "$(osrc_remote_state del)" = failed ] && ok "branch deleted after being seen: EVENT failed, state failed" || bad "deleted branch: $ev"
cmd_lane rm del >/dev/null && [ ! -f "$OSRC_HOME/remote/del.json" ] && [ ! -f "$OSRC_HOME/owners/sess-test-l2/del" ] && [ "$(osrc_remote_state del)" = gone ] && ok "lane rm removes metadata and the owner record" || bad "lane rm incomplete"
ll="$(cmd_lane ls)"; echo "$ll" | grep -q 'cloud1' && ok "lane ls lists lanes" || bad "lane ls"

# ---- 17. the CLI works end-to-end through a PATH symlink (the loader finds lib/ via BASH_SOURCE) ------------------------------
mkdir -p "$TMP/linkbin"; ln -s "$SRC" "$TMP/linkbin/outsourcerer"
out="$(OSRC_SOURCED= PATH="$TMP/linkbin:$PATH" outsourcerer lane ls 2>&1)"; echo "$out" | grep -q 'LANE' && ok "lane via a PATH launcher symlink" || bad "symlink launch: $out"
out="$(OSRC_SOURCED= PATH="$TMP/linkbin:$PATH" outsourcerer review queue ls 2>&1)"; echo "$out" | grep -q 'reviewer:' && ok "review via a PATH launcher symlink" || bad "symlink review: $out"

echo "---- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
