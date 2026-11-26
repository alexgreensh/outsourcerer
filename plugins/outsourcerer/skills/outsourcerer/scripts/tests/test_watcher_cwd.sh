#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_watcher_cwd.sh -- the watcher must not go blind when the folder it was started in is deleted.
# Incident: supervise ran as a background command inside a git worktree that was later removed;
# every remote poll then died with "fatal: Unable to read current working directory", the lane
# record froze, and a lane that had pushed READY hours earlier was announced as `stalled`.
#   1. supervise started from a temp dir that is then deleted still delivers a READY push.
#   2. a poll that fails is `EVENT poll-failed <id> <reason>` (once per reason), never `stalled`,
#      and `lane ls` / Mission Control say "can't check" with the reason.
# Offline: a local bare repo is the remote; a fake gh answers errors.
set -uo pipefail
export OSRC_CARD_GUARD=0
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "${TMPDIR%/}/.test-watcher-cwd.XXXXXX")" || { echo "FAIL: scratch" >&2; exit 1; }
SPID=""; trap '[ -z "$SPID" ] || kill "$SPID" 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
export OSRC_HOME="$TMP/state" HOME="$TMP/home" CLAUDE_CODE_SESSION_ID="sess-watcher-cwd"
mkdir -p "$OSRC_HOME" "$HOME" "$TMP/bin"
export OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0 OSRC_SELF=osrc GIT_TERMINAL_PROMPT=0
export OSRC_SUPERVISE_POLL=1 OSRC_SUPERVISE_CONFIRM=0 OSRC_SUPERVISE_SETTLE=0 OSRC_SUPERVISE_TICK_SECS=86400
export OSRC_REMOTE_POLL_SECS=0 OSRC_CLAUDE_PROJECTS_DIR="$TMP/projects" OSRC_CLAUDE_SESSIONS_DIR="$TMP/ccsessions"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$OSRC_HOME/supervise/$CLAUDE_CODE_SESSION_ID"; date +%s > "$OSRC_HOME/supervise/$CLAUDE_CODE_SESSION_ID/tick.time"

REMOTE="$TMP/remote.git"; WORK="$TMP/work"
git init -q --bare "$REMOTE"; git clone -q "$REMOTE" "$WORK" 2>/dev/null
( cd "$WORK" && git checkout -q -b main && echo base > f && git add f && git commit -q -m base && git push -q origin main )
push() { ( cd "$WORK" && { git checkout -q "$1" 2>/dev/null || git checkout -q -b "$1" main; }
  echo "$RANDOM" > "c.$RANDOM" && git add -A && git commit -q -m "$2" && git push -q origin "$1" 2>/dev/null && git rev-parse HEAD ); }
L() { ( cd "$TMP" && "$SRC" lane "$@" ); }

# ---- 1. supervise from a folder deleted after start ----------------------------------------------
L add wl1 --branch cloud/wl1 --repo "$REMOTE" >/dev/null 2>&1 || bad "lane add"
h0="$(push cloud/wl1 "wip: start")"
( cd "$TMP" && "$SRC" lane poll wl1 ) >/dev/null 2>&1
mkdir -p "$TMP/gone-wt"
( cd "$TMP/gone-wt" && exec perl -e 'alarm shift; exec @ARGV' 60 "$SRC" supervise --session "$CLAUDE_CODE_SESSION_ID" ) >"$TMP/sv.out" 2>"$TMP/sv.err" &
SPID=$!
sleep 2; rm -rf "$TMP/gone-wt"
h1="$(push cloud/wl1 "READY: wl1 done")"
i=0; while [ "$i" -lt 45 ] && ! grep -q '^EVENT done wl1 ' "$TMP/sv.out" 2>/dev/null; do sleep 1; i=$((i+1)); done
grep -q "^EVENT done wl1 .*READY ${h1:0:7}" "$TMP/sv.out" && ok "supervise started in a deleted folder still delivers the READY push" \
  || bad "READY not delivered after the start folder was deleted: $(head -c 400 "$TMP/sv.out") / $(cat "$OSRC_HOME/remote/wl1.fetch.err" 2>/dev/null | tail -1) / $(jq -c '{head,err_kind,err_msg}' "$OSRC_HOME/remote/wl1.json")"
grep -q 'Unable to read current working directory' "$OSRC_HOME/remote/wl1.fetch.err" 2>/dev/null \
  && bad "a git call ran from the deleted folder" || ok "no git call ran from the deleted folder"
kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null; SPID=""

# ---- 2. a failing poll is poll-failed, never stalled on stale data --------------------------------
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh: To use GitHub CLI in a script, authenticate with gh auth login (HTTP 401)" >&2; exit 1
SH
chmod +x "$TMP/bin/gh"
OSRC_SOURCED=1; export OSRC_SOURCED; set --; PATH="$TMP/bin:$PATH" . "$SRC" >/dev/null 2>&1
export PATH="$TMP/bin:$PATH" OSRC_TIME_UNIT=1 OSRC_REMOTE_STALL=90 OSRC_NOW=2000000
cmd_lane add gl1 --branch cloud/gl1 --repo acme/widgets >/dev/null 2>&1
f="$OSRC_HOME/remote/gl1.json"
# the lane pushed once (old head), then every poll fails for longer than the stall timeout
_osrc_jq_set "$f" --argjson t 1999000 '.head="aaaaaaa1111111111111111111111111111111aa" | .seen_branch=true | .last_push_ts=$t | .created_ts=$t'
out="$(osrc_remote_events 2>&1)"
grep -q '^EVENT poll-failed gl1 .*auth' <<<"$out" && ok "a failing poll is EVENT poll-failed with the reason" || bad "no poll-failed: $out"
grep -q '^NEXT gh auth status' <<<"$out" && ok "poll-failed NEXT names the fix" || bad "NEXT: $out"
grep -q '^EVENT stalled gl1' <<<"$out" && bad "stale data reported as stalled: $out" || ok "a lane that cannot be checked is not called stalled"
OSRC_NOW=2000500; out="$(osrc_remote_events 2>&1)"
grep -q 'poll-failed gl1' <<<"$out" && bad "same reason reported twice: $out" || ok "poll-failed is reported once per reason"
grep -q '^EVENT stalled gl1' <<<"$out" && bad "stalled on the second pass: $out" || ok "still not stalled on the next pass"
row="$(cmd_lane ls 2>/dev/null | grep -E '^gl1 ')"
grep -q "can't check" <<<"$row" && ok "lane ls shows can't check" || bad "ls: $row"
lane="$(_osrc_hub_lane_remote gl1)"
jq -e '.status == "Can'"'"'t check" and (.note | test("auth"))' <<<"$lane" >/dev/null && ok "Mission Control shows the lane as Can't check with the reason" || bad "hub lane: $lane"
# the deleted-cwd error class is named and reported at once
_osrc_lane_poll_err gl1 "$f" "$OSRC_NOW" net "fatal: Unable to read current working directory: No such file or directory"
[ "$(jq -r .err_kind "$f")" = cwd ] && ok "a lost working directory is its own poll error class" || bad "kind $(jq -r .err_kind "$f")"
# a good poll clears the episode, so a later failure is reported again
_osrc_jq_set "$f" '.err_count=0 | .err_kind="" | .err_msg=""'; rm -f "$OSRC_HOME/remote/.ev/gl1"/pollfail*
OSRC_NOW=2001000; out="$(osrc_remote_events 2>&1)"
grep -q '^EVENT poll-failed gl1' <<<"$out" && ok "a new failure episode is reported again" || bad "new episode silent: $out"

echo "test_watcher_cwd: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
