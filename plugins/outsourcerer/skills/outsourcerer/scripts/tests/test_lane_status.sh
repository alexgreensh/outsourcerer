#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_lane_status.sh -- honest remote-lane status: a missing cloud branch means "starting" (gh HTTP 422),
# a lane that never pushes is reported once as "never started", real network errors still surface,
# and `lane ls` derives its state from evidence (age, branch), not from a stale cached `live`.
# Offline: a PATH stub stands in for gh; the clock is fake (OSRC_NOW, OSRC_TIME_UNIT=1).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "${TMPDIR%/}/.test-lane-status.XXXXXX")" || { echo "FAIL: scratch" >&2; exit 1; }; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
export OSRC_HOME="$TMP/state" HOME="$TMP/home" CLAUDE_CODE_SESSION_ID="sess-test-lane-status"
mkdir -p "$OSRC_HOME" "$HOME" "$TMP/bin"
export OSRC_TIME_UNIT=1 OSRC_REMOTE_POLL_SECS=0 OSRC_SELF=osrc OSRC_NOW=1000000 OSRC_REMOTE_STALL=90 OSRC_REMOTE_NEVER_START=45
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# Round 3: optional routes for the session-branch lookup (matching-refs, then that branch's commit)
case "$*" in
  *matching-refs*) if [ -f "${GH_REFS:-}" ]; then cat "$GH_REFS"; exit 0; fi ;;
  *commits/claude/*) if [ -f "${GH_ALT:-}" ]; then cat "$GH_ALT"; exit 0; fi ;;
esac
if [ -f "$GH_ERR" ]; then cat "$GH_ERR" >&2; exit 1; fi
cat "$GH_OUT"
SH
chmod +x "$TMP/bin/gh"; export GH_ERR="$TMP/gh.err" GH_OUT="$TMP/gh.out" PATH="$TMP/bin:$PATH"
OSRC_SOURCED=1; export OSRC_SOURCED; set --; . "$SRC" >/dev/null 2>&1

add() { cmd_lane add "$1" --branch "cloud/$1" --repo acme/widgets >/dev/null 2>&1; }
errs() { jq -r '.err_count' "$OSRC_HOME/remote/$1.json"; }

# Incident: gh answered HTTP 422 five times for a cloud/<id> branch not pushed yet -> EVENT failed.
printf 'gh: No commit found for SHA: cloud/c1 (HTTP 422)\n' > "$GH_ERR"
add c1
for _ in 1 2 3 4 5 6; do cmd_lane poll c1; done
[ "$(errs c1)" = 0 ] && ok "HTTP 422 on a not-yet-pushed branch is not a poll error" || bad "422 counted as error ($(errs c1))"
out="$(osrc_remote_events 2>&1)"
grep -q 'EVENT failed c1' <<<"$out" && bad "healthy starting lane reported failed: $out" || ok "no EVENT failed while the branch is missing"
[ "$(osrc_remote_state c1)" = live ] && ok "state stays live (starting)" || bad "state $(osrc_remote_state c1)"
grep -q 'starting' <<<"$(cmd_lane ls)" && ok "lane ls says starting" || bad "ls: $(cmd_lane ls)"

# A lane that never pushes: one 'never started' event, then silence.
OSRC_NOW=$((1000000 + 46)); export OSRC_NOW
out="$(osrc_remote_events 2>&1)"
grep -q 'EVENT failed c1 .*never started' <<<"$out" && ok "never-pushed lane reports 'never started'" || bad "no never-started event: $out"
out="$(osrc_remote_events 2>&1)"
grep -q 'never started' <<<"$out" && bad "never-started repeated" || ok "never-started is reported once"
grep -q 'stale' <<<"$(cmd_lane ls)" && ok "lane ls shows the never-pushed lane stale" || bad "ls: $(cmd_lane ls)"

# Round 2: "never started" is the ONLY report for a headless lane; no stalled event 90m later.
OSRC_NOW=$((1000000 + 91)); export OSRC_NOW
out="$(osrc_remote_events 2>&1)"
grep -q 'EVENT stalled c1' <<<"$out" && bad "headless lane also reported stalled: $out" || ok "headless lane is not reported stalled after never started"

# Real network errors still surface (and a missing branch must not mask them).
OSRC_NOW=1000000; export OSRC_NOW
printf 'gh: error connecting to api.github.com\n' > "$GH_ERR"
add c2
for _ in 1 2 3 4 5 6; do cmd_lane poll c2; done
out="$(osrc_remote_events 2>&1)"; grep -q 'EVENT failed c2 .*polling failed' <<<"$out" && ok "real network errors still surface" || bad "network error hidden"

# Evidence-based ls: a lane that pushed once, then went quiet past the stall timeout, is stale not live.
rm -f "$GH_ERR"
printf '{"sha":"%s","commit":{"message":"wip"},"files":[]}\n' "$(printf 'a%.0s' $(seq 40))" > "$GH_OUT"
add c3; cmd_lane poll c3
row="$(cmd_lane ls | grep -E '^c3 ')"; grep -q ' live ' <<<"$row" && ok "fresh push shows live" || bad "ls: $(cmd_lane ls)"
OSRC_NOW=$((1000000 + 91)); export OSRC_NOW
row="$(cmd_lane ls | grep -E '^c3 ')"; grep -q ' stale ' <<<"$row" && ok "no evidence past the timeout shows stale" || bad "ls: $(cmd_lane ls)"

# Round 2: ls and events share one last-move rule: a recent review verdict keeps a lane live in both.
rm -f "$GH_ERR"; OSRC_NOW=1000000; export OSRC_NOW
add c4; cmd_lane poll c4
_osrc_review_last_verdict_ts() { echo "${FAKE_VTS:-0}"; }
OSRC_NOW=$((1000000 + 91)); FAKE_VTS=$((1000000 + 80)); export OSRC_NOW FAKE_VTS
row="$(cmd_lane ls | grep -E '^c4 ')"; grep -q ' live ' <<<"$row" && ok "ls honours the last review verdict (not stale)" || bad "ls ignored the verdict: $row"
out="$(osrc_remote_events 2>&1)"
grep -q 'EVENT stalled c4' <<<"$out" && bad "events stalled c4 despite verdict" || ok "events agree: not stalled"
unset -f _osrc_review_last_verdict_ts

# Round 2: a session that pushed only to its own claude/<id>-<suffix> branch is found; READY there counts.
OSRC_NOW=1000000; export OSRC_NOW
O="$TMP/origin.git"; W="$TMP/w"
git init -q --bare "$O" && git init -q "$W" && git -C "$W" config user.email t@example.invalid && git -C "$W" config user.name t
git -C "$W" commit -q --allow-empty -m init && git -C "$W" push -q "$O" HEAD:refs/heads/main
printf 'READY alt1\n' > "$W/alt1.READY"; git -C "$W" add alt1.READY && git -C "$W" commit -q -m "alt1: done READY"
git -C "$W" push -q "$O" HEAD:refs/heads/claude/alt1-Xk3Q
cmd_lane add alt1 --branch cloud/alt1 --repo "$O" >/dev/null 2>&1; cmd_lane poll alt1
[ "$(jq -r .head_ready "$OSRC_HOME/remote/alt1.json")" = true ] && [ "$(jq -r .poll_branch "$OSRC_HOME/remote/alt1.json")" = claude/alt1-Xk3Q ] \
  && ok "READY on the session's own claude/<id>-* branch is seen" || bad "alt branch missed: $(jq -c . "$OSRC_HOME/remote/alt1.json")"
OSRC_REMOTE_NEVER_START=45 cmd_lane add alt2 --branch cloud/alt2 --repo "$O" >/dev/null 2>&1; cmd_lane poll alt2
[ "$(jq -r .head "$OSRC_HOME/remote/alt2.json")" = "" ] && ok "another lane's session branch is not adopted" || bad "alt2 adopted a foreign branch"
# Round 3 (P2-2): the review item and the done event name the branch the READY commit is on.
item="$(ls "$OSRC_HOME"/review/items/alt1-*.json 2>/dev/null | head -1)"
[ -n "$item" ] && [ "$(jq -r .branch "$item")" = claude/alt1-Xk3Q ] && ok "review item fetches the session branch" || bad "review item branch: $(jq -c . "$item" 2>/dev/null)"
out="$(osrc_remote_events 2>&1)"
grep -q 'EVENT done alt1 .*READY .* on claude/alt1-Xk3Q' <<<"$out" && ok "done event names the session branch" || bad "done event: $out"

# Round 3 (P1): lane ids that are prefixes of each other: `alt` must not adopt claude/alt-r2-*.
git -C "$W" push -q "$O" HEAD:refs/heads/claude/alt-r2-fixes-x9
cmd_lane add alt-r2 --branch cloud/alt-r2 --repo "$O" >/dev/null 2>&1
cmd_lane add alt --branch cloud/alt --repo "$O" >/dev/null 2>&1
cmd_lane poll alt; cmd_lane poll alt-r2
[ "$(jq -r .head "$OSRC_HOME/remote/alt.json")" = "" ] && ok "lane alt does not adopt claude/alt-r2-* (git)" || bad "alt adopted: $(jq -c . "$OSRC_HOME/remote/alt.json")"
[ "$(jq -r .poll_branch "$OSRC_HOME/remote/alt-r2.json")" = claude/alt-r2-fixes-x9 ] && ok "lane alt-r2 still follows its own branch" || bad "alt-r2 lost its branch"

# Round 3 (P2-3): a lane branch seen once and then deleted is reported deleted, not swapped for the session branch.
git -C "$W" push -q "$O" HEAD:refs/heads/cloud/alt3 && cmd_lane add alt3 --branch cloud/alt3 --repo "$O" >/dev/null 2>&1 && cmd_lane poll alt3
git -C "$W" push -q "$O" HEAD:refs/heads/claude/alt3-k2 && git -C "$W" push -q "$O" :refs/heads/cloud/alt3; cmd_lane poll alt3
[ "$(jq -r .branch_deleted "$OSRC_HOME/remote/alt3.json")" = true ] && [ "$(jq -r .poll_branch "$OSRC_HOME/remote/alt3.json")" = cloud/alt3 ] \
  && ok "deleted lane branch is reported, not silently swapped" || bad "deleted branch swapped: $(jq -c . "$OSRC_HOME/remote/alt3.json")"

# Round 4 (P2-1): a followed session branch stays followed when a second claude/<id>-* branch sorts first.
git -C "$W" push -q "$O" HEAD:refs/heads/claude/alt1-AAA-new; cmd_lane poll alt1
[ "$(jq -r .poll_branch "$OSRC_HOME/remote/alt1.json")" = claude/alt1-Xk3Q ] && [ "$(jq -r .branch_deleted "$OSRC_HOME/remote/alt1.json")" = false ] \
  && ok "followed branch kept when another claude/<id>-* sorts first" || bad "followed lane flipped: $(jq -c . "$OSRC_HOME/remote/alt1.json")"

# Round 4 (P2-2): cleanup offers only merged or BLOCKed work, never a live lane, never a deleted branch.
out="$(_osrc_cleanup_remote_branches)"
grep -q 'lane alt1 ' <<<"$out" && bad "cleanup offered a READY (unfinished) lane: $out" || ok "cleanup never offers an unfinished lane"
grep -q 'lane alt3 ' <<<"$out" && bad "cleanup offered a branch-deleted lane: $out" || ok "cleanup skips a lane whose branch is gone"
mkdir -p "$OSRC_HOME/cloud"; printf 'pushed to claude/alt1-Zz9.\n' > "$OSRC_HOME/cloud/alt1.launch.log"
out="$( _osrc_review_verdict_for() { echo MERGE; }; _osrc_cleanup_remote_branches)"
grep -q 'lane alt1 ' <<<"$out" && bad "cleanup offered approved-but-unmerged work: $out" || ok "cleanup keeps a MERGE verdict that has not landed"
out="$( _osrc_review_verdict_for() { echo BLOCK; }; _osrc_cleanup_remote_branches)"
grep -q 'lane alt1 .*--delete claude/alt1-Xk3Q$' <<<"$out" && ok "cleanup offers only the branch the lane pushed, nothing from the log" || bad "cleanup offer: $out"
out="$( _osrc_review_verdict_for() { :; }; _osrc_review_item_closed_merged() { return 0; }; _osrc_cleanup_remote_branches)"
grep -q 'lane alt1 .*--delete claude/alt1-Xk3Q$' <<<"$out" && ok "cleanup offers a lane whose item closed as merged" || bad "closed-merged not offered: $out"
cp "$OSRC_HOME/remote/alt1.json" "$TMP/alt1.bak"
jq '.check = {head: .head, state: "done", rc: 1}' "$TMP/alt1.bak" > "$OSRC_HOME/remote/alt1.json"
out="$( _osrc_review_verdict_for() { echo MERGE; }; _osrc_cleanup_remote_branches)"; mv "$TMP/alt1.bak" "$OSRC_HOME/remote/alt1.json"
grep -q 'lane alt1 ' <<<"$out" && bad "cleanup offered a lane whose done-when check failed: $out" || ok "a failed done-when check is not offered"

# Final fix: a launch-log name the remote does not have (wrapped, truncated, stale) never hides the real branch.
printf '{}' > "$OSRC_HOME/lgx.json"; printf 'pushed to claude/lgx-fix\n' > "$OSRC_HOME/cloud/lgx.launch.log"
b="$(_osrc_lane_alt_branch lgx "$OSRC_HOME/lgx.json" git x "$(printf 'abc\trefs/heads/claude/lgx-fixes-8v\n')")"
[ "$b" = claude/lgx-fixes-8v ] && ok "absent launch-log name falls back to the remote's real branch" || bad "followed an absent log name: '$b'"
printf 'pushed to claude/lgx-fixes-8v.\n' > "$OSRC_HOME/cloud/lgx.launch.log"
b="$(_osrc_lane_alt_branch lgx "$OSRC_HOME/lgx.json" git x "$(printf 'a\trefs/heads/claude/lgx-aaa\nb\trefs/heads/claude/lgx-fixes-8v\n')")"
[ "$b" = claude/lgx-fixes-8v ] && ok "launch-log name still preferred when the remote has it" || bad "log preference lost: '$b'"
rm -f "$OSRC_HOME/lgx.json" "$OSRC_HOME/cloud/lgx.launch.log"

# Round 3 (P2-5): the gh transport finds the session branch via matching-refs, and drops a longer lane's.
rm -f "$GH_ERR"; printf 'gh: No commit found for SHA: cloud/g1 (HTTP 422)\n' > "$GH_ERR"
export GH_REFS="$TMP/refs.json" GH_ALT="$TMP/alt.json"
printf '[{"ref":"refs/heads/claude/g1-r2-zz"},{"ref":"refs/heads/claude/g1-Ab12"}]\n' > "$GH_REFS"
printf '{"sha":"%s","commit":{"message":"g1: READY"},"files":[]}\n' "$(printf 'b%.0s' $(seq 40))" > "$GH_ALT"
add g1-r2; add g1; cmd_lane poll g1
[ "$(jq -r .poll_branch "$OSRC_HOME/remote/g1.json")" = claude/g1-Ab12 ] && [ "$(jq -r .head_ready "$OSRC_HOME/remote/g1.json")" = true ] \
  && ok "gh: session branch found via matching-refs, READY seen" || bad "gh alt path: $(jq -c . "$OSRC_HOME/remote/g1.json")"
unset GH_REFS GH_ALT

# Round 3 (P3-6): "never started" is not claimed while polls are failing (nobody checked).
printf 'gh: error connecting to api.github.com\n' > "$GH_ERR"
OSRC_NOW=1000000; export OSRC_NOW; add n1; cmd_lane poll n1
OSRC_NOW=$((1000000 + 46)); export OSRC_NOW
grep -q 'EVENT failed n1 .*never started' <<<"$(osrc_remote_events 2>&1)" && bad "never started claimed while polls fail" || ok "no 'never started' while polls are failing"

echo "=== $pass passed, $fail failed ==="; [ "$fail" -eq 0 ]
