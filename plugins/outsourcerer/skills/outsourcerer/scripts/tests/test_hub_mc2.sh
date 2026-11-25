#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR%/}/osrc-mc2.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" OSRC_HOME="$T/osrc" OSRC_JOBS="$T/osrc/jobs"
mkdir -p "$HOME/.claude/projects/p" "$OSRC_HOME/owners" "$OSRC_JOBS" "$T/bin"
. "$ROOT/lib/hub-names.sh"
mkdir -p "$T/repository" "$OSRC_HOME/owners/abcdefgh-1" "$OSRC_JOBS/one"
git -C "$T/repository" init -q
git -C "$T/repository" remote add origin https://github.com/example/demo.git
printf '{"cwd":"%s"}\n' "$T/repository" > "$OSRC_JOBS/one/meta.json"
touch "$OSRC_HOME/owners/abcdefgh-1/one"
[ "$(_osrc_hub_derived_name abcdefgh-1)" = 'Demo' ]   # r3: no owner, no id
mkdir -p "$OSRC_HOME/owners/12345678-2"
touch "$OSRC_HOME/owners/12345678-2/one"
[ "$(_osrc_hub_derived_name 12345678-2)" = 'Demo' ]
mkdir -p "$T/folder" "$OSRC_HOME/owners/folder-id" "$OSRC_JOBS/two"
printf '{"cwd":"%s"}\n' "$T/folder" > "$OSRC_JOBS/two/meta.json"
touch "$OSRC_HOME/owners/folder-id/two"
[ "$(_osrc_hub_derived_name folder-id)" = 'Folder' ]
printf '%s\n' '{"type":"user","message":{"content":"Build the mission control dashboard"}}' > "$HOME/.claude/projects/p/prompt-id.jsonl"
[ -z "$(_osrc_hub_derived_name prompt-id)" ] && [ "$(_osrc_hub_session_detail prompt-id)" = 'Build the mission control dashboard' ]   # MC3 Titles: a first prompt is cut at ~6 words, not 32 chars
printf '%s\n' '{"type":"custom-title","customTitle":"A named session"}' >> "$HOME/.claude/projects/p/prompt-id.jsonl"
[ "$(_osrc_hub_session_detail prompt-id)" = 'A named session' ]
[ -z "$(_osrc_hub_derived_name missing-id)$(_osrc_hub_session_detail missing-id)" ]
_osrc_hub_daily_hint 2> "$T/first"
_osrc_hub_daily_hint 2> "$T/second"
[ "$(cat "$T/first")" = 'Mission Control: outsourcerer mc' ]
[ ! -s "$T/second" ]
mkdir -p "$OSRC_HOME/owners/old-session" "$OSRC_JOBS/old-job" "$OSRC_HOME/hub/decisions"
printf 'done\n' > "$OSRC_JOBS/old-job/status"
printf '{}\n' > "$OSRC_JOBS/old-job/meta.json"
touch "$OSRC_HOME/owners/old-session/old-job"
export OSRC_CATALOG_VALIDATE=0 OUTSOURCERER_DEPTH=0
out="$(bash "$ROOT/outsourcerer.sh" hub export --project old-session 2>/dev/null)"
printf '%s' "$out" | jq -e '.projects[] | select(.id == "old-session") | .liveLanes == 0 and .status == "idle" and .staleHours == 24' >/dev/null
ln -s "$ROOT/outsourcerer.sh" "$T/osrc-link"
linked="$(bash "$T/osrc-link" hub export --project old-session 2>/dev/null)"
printf '%s' "$linked" | jq -e '.projects[] | select(.id == "old-session") | .status == "idle"' >/dev/null
printf 'PASS: MC2 naming, hint, idle export and symlink loader\n'

# ---- Round 2 -------------------------------------------------------------------------------------
FX="$ROOT/tests/fixtures/screen"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
nm() { printf '%s\n' "$2" > "$HOME/.claude/projects/p/$1.jsonl"; _osrc_hub_session_detail "$1"; }

# #3 names: chat noise stripped, slash commands dropped, word-boundary cut with an ellipsis, meta skipped.
[ "$(nm img '{"type":"user","message":{"content":[{"type":"text","text":"[Image #1] something is really, really wrong, either with the token optimizer"}]}}')" = 'something is really, really wrong, either…' ] || fail "image token: $(_osrc_hub_session_detail img)"
[ "$(nm paste '{"type":"user","message":{"content":"\n\n<pasted_content id=\"b887\">\nToken Optimizer savings audit.\n</pasted_content>"}}')" = 'Token Optimizer savings audit.' ] || fail "pasted_content: $(_osrc_hub_session_detail paste)"
[ "$(nm ptext '{"type":"user","message":{"content":"[Pasted text #2 +40 lines] ship the hub fix"}}')" = 'ship the hub fix' ] || fail 'pasted text token'
[ "$(nm slash '{"type":"user","message":{"content":"/review fix the login bug"}}')" = 'fix the login bug' ] || fail 'leading slash command'
[ "$(nm cmd '{"type":"user","message":{"content":"<command-message>recall</command-message>\n<command-name>/recall</command-name>\n<command-args>find the TR plan</command-args>"}}')" = 'find the TR plan' ] || fail "command wrapper: $(_osrc_hub_session_detail cmd)"
printf '%s\n%s\n' '{"type":"user","isMeta":true,"message":{"content":"Base directory for this skill"}}' '{"type":"user","message":{"content":"The real ask"}}' > "$HOME/.claude/projects/p/meta.jsonl"
[ "$(_osrc_hub_session_detail meta)" = 'The real ask' ] || fail 'isMeta not skipped'
# Cached by session id; a grown transcript (here a rename) is read again.
[ "$(cut -d' ' -f2- "$OSRC_HOME/hub/titles-v4/meta")" = 'The real ask' ] || fail 'name not cached'
printf '%s\n' '{"type":"custom-title","customTitle":"[Image #3] Renamed  session"}' >> "$HOME/.claude/projects/p/meta.jsonl"
[ "$(_osrc_hub_session_detail meta)" = 'Renamed session' ] || fail "cache not invalidated: $(_osrc_hub_session_detail meta)"
printf 'PASS: MC2 r2 #3 names cleaned and cached\n'

# A tmux stand-in fed by REAL pane captures (fixtures/screen). No tmux server is touched at all.
mkdir -p "$T/faketmux"; export FAKE_TMUX="$T/faketmux"
cat > "$T/bin/tmux" <<'SH'
#!/bin/sh
D="$FAKE_TMUX"; cmd="$1"; shift; t=""; fmt=""
while [ $# -gt 0 ]; do case "$1" in -t) t="${2#=}"; shift 2 ;; -F) fmt="$2"; shift 2 ;; -*) shift ;; *) fmt="$1"; shift ;; esac; done
case "$cmd" in
  list-sessions) cat "$D/sessions" ;;
  has-session) grep -q "^$t " "$D/sessions" ;;
  display-message) line="$(grep "^$t " "$D/sessions")" || exit 1; set -- $line
    case "$fmt" in *session_created*) echo "$2 $3" ;; *) echo "$3" ;; esac ;;
  capture-pane) cat "$D/$t.ansi" 2>/dev/null ;;
  *) exit 0 ;;
esac
SH
chmod 755 "$T/bin/tmux"; export PATH="$T/bin:$PATH"
now="$(date +%s)"; : > "$FAKE_TMUX/sessions"; mkdir -p "$OSRC_HOME/owners/live-sess" "$OSRC_HOME/sessions"
for pair in work:cc-working-hooks perm:cc-permission-bash idle:cc-idle-after-work; do
  n="osrc-test-MC2-${pair%%:*}"; cp "$FX/${pair#*:}.ansi" "$FAKE_TMUX/$n.ansi"
  printf '%s %s %s\n' "$n" "$((now - 7200))" "$((now - 600))" >> "$FAKE_TMUX/sessions"
  printf '{"event":"start","session_id":"%s","provider":"cc","model":"claude-opus-5-5","ts":%s}\n' "$n" "$((now - 7200))" >> "$OSRC_HOME/sessions/registry.jsonl"
  touch "$OSRC_HOME/owners/live-sess/$n"
done
mkdir -p "$OSRC_HOME/hub/projects"; printf '{"pct":0}\n' > "$OSRC_HOME/hub/projects/live-sess.json"

# #5 live lanes carry what they are doing and since when; #2 a real 0 survives, no pct stays absent.
out="$(bash "$ROOT/outsourcerer.sh" hub export 2>/dev/null)"
lv() { printf '%s' "$out" | jq -r --arg n "osrc-test-MC2-$1" '.projects[] | select(.id == "live-sess") | .lanes[] | select(.id == $n) | "\(.state) \(.startedAt) \(.activeAt) \(.model)"'; }
[ "$(lv work)" = "working $((now - 7200)) $((now - 600)) claude-opus-5-5" ] || fail "working lane: $(lv work)"
[ "$(lv perm | cut -d' ' -f1)" = approval ] || fail "approval lane: $(lv perm)"
[ "$(lv idle | cut -d' ' -f1)" = idle ] || fail "idle lane: $(lv idle)"
printf '%s' "$out" | jq -e '.projects[] | select(.id == "live-sess") | .pct == 0' >/dev/null || fail 'real 0% lost'
# No report and no board: no percent, never one made from lane counts (lib/hub-truth.sh).
bash "$ROOT/outsourcerer.sh" hub export --project old-session 2>/dev/null | jq -e '.projects[] | select(.id == "old-session") | (has("pct") | not) and .source == "live"' >/dev/null || fail 'unknown pct invented'
printf 'PASS: MC2 r2 #2 pct and #5 lane state from real captures\n'

# #4 per-export memo: the stock readers come back after the export, and the memo dir is gone.
(
  OSRC_SOURCED=1; export OSRC_SOURCED; set --; . "$ROOT/outsourcerer.sh" >/dev/null 2>&1
  raw="$(_state_jsonl_read "$OSRC_SESSION_REGISTRY" | jq -c .)"
  mkdir -p "$OSRC_HOME/hub/memo.99999/reg"   # left by a killed export (pid 99999 cannot exist on macOS)
  _osrc_hub_memo_begin
  [ ! -d "$OSRC_HOME/hub/memo.99999" ] || fail 'stale memo of a dead export not swept'
  [ "$(_state_jsonl_read "$OSRC_SESSION_REGISTRY")" = "$raw" ] || fail 'memo registry differs'
  [ "$(_session_registry_last_event osrc-test-MC2-perm | jq -r .session_id)" = osrc-test-MC2-perm ] || fail 'memo last event'
  _osrc_hub_memo_end
  ! type _osrc_hub_raw_state_jsonl_read >/dev/null 2>&1 || fail 'raw reader not restored'
  ! ls -d "$OSRC_HOME"/hub/memo.* >/dev/null 2>&1 || fail 'memo dir left behind'
) || exit 1

# #4 settled-project cache (OSRC_HUB_FAST=1, set by hub serve): a hit until an input changes; live never cached.
OSRC_HUB_FAST=1 bash "$ROOT/outsourcerer.sh" hub export >/dev/null 2>&1
[ -f "$OSRC_HOME/hub/cache/old-session.json" ] || fail 'settled project not cached'
[ ! -f "$OSRC_HOME/hub/cache/live-sess.json" ] || fail 'live project cached'
jq -c '.name = "from-cache"' "$OSRC_HOME/hub/cache/old-session.json" > "$T/c" && cat "$T/c" > "$OSRC_HOME/hub/cache/old-session.json"
nm2() { OSRC_HUB_FAST=1 bash "$ROOT/outsourcerer.sh" hub export --project old-session 2>/dev/null | jq -r '.projects[] | select(.id == "old-session") | .name'; }
[ "$(nm2)" = from-cache ] || fail 'cache not used'
sleep 1; touch "$OSRC_JOBS/old-job/status"
[ "$(nm2)" != from-cache ] || fail 'changed job did not invalidate the cache'
[ "$(bash "$ROOT/outsourcerer.sh" hub export --project old-session 2>/dev/null | jq -r '.projects[] | select(.id == "old-session") | .name')" != from-cache ] || fail 'plain export used the cache'
# Limits: served from the cache under FAST, computed under a plain export.
printf '[{"id":"cached-row"}]\n' > "$OSRC_HOME/hub/limits-cache.json"
OSRC_HUB_FAST=1 bash "$ROOT/outsourcerer.sh" hub export 2>/dev/null | jq -e '[.limits[].id] == ["cached-row"]' >/dev/null || fail 'limits cache unused'
bash "$ROOT/outsourcerer.sh" hub export 2>/dev/null | jq -e '[.limits[]?.id] | index("cached-row") | not' >/dev/null || fail 'plain export read the limits cache'
printf 'PASS: MC2 r2 #4 memo, settled cache and limits cache\n'

# ---- Round 3: names a person would say, working sessions only ----------------------------------
ex() { bash "$ROOT/outsourcerer.sh" hub export "$@" 2>/dev/null; }
pname() { printf '%s' "$1" | jq -r --arg id "$2" '.projects[] | select(.id == $id) | .name'; }
shown() { printf '%s' "$1" | jq -e --arg id "$2" 'any(.projects[]; .id == $id)' >/dev/null; }
old() { touch -t "$(date -r $(( $(date +%s) - $1 * 60 )) '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$(( $(date +%s) - $1 * 60 ))" '+%Y%m%d%H%M.%S')" "$2"; }
[ "$(_osrc_hub_humanize alexgreensh/total-recall-core)" = 'Total Recall Core' ] || fail 'humanize owner/repo'
[ "$(_osrc_hub_humanize outsourcerer.git)" = 'Outsourcerer' ] || fail 'humanize plain repo'
[ "$(_osrc_hub_humanize git@x:me/my_tool)" = 'My Tool' ] || fail "humanize underscores: $(_osrc_hub_humanize git@x:me/my_tool)"
# Three working sessions in one repo, told apart by what each is doing, never by an id.
sess() { # <sid> <transcript line>
  mkdir -p "$OSRC_HOME/owners/$1" "$OSRC_JOBS/$1-job"; printf 'done\n' > "$OSRC_JOBS/$1-job/status"
  printf '{"cwd":"%s"}\n' "$T/repository" > "$OSRC_JOBS/$1-job/meta.json"; touch "$OSRC_HOME/owners/$1/$1-job"
  printf '%s\n' "$2" > "$HOME/.claude/projects/p/$1.jsonl"; }
sess s-ship '{"type":"custom-title","customTitle":"ship 0.16.1"}'
sess s-side '{"type":"user","message":{"content":"fix the sidebar see https://github.com/a/b and lib/hub.sh 2957d198"}}'
sess s-none '{"type":"user","isMeta":true,"message":{"content":"Base directory for this skill"}}'
sess s-sum '{"type":"summary","summary":"Release notes for 0.16.1"}'
out="$(ex)"
[ "$(pname "$out" s-ship)" = 'Demo · ship 0.16.1' ] || fail "custom title: $(pname "$out" s-ship)"
[ "$(pname "$out" s-side)" = 'Demo · fix the sidebar see and' ] || fail "cleaned prompt: $(pname "$out" s-side)"
[ "$(pname "$out" s-sum)" = 'Demo · Release notes for 0.16.1' ] || fail "summary line: $(pname "$out" s-sum)"
[ "$(pname "$out" s-none)" = 'Demo' ] || fail "nothing usable (MC3: unique without a suffix): $(pname "$out" s-none)"
printf '%s' "$out" | jq -e '[.projects[].name | test("https?:|/|[0-9a-f]{8}|\\(")] | any | not' >/dev/null || fail "an id, URL or path in a name: $(printf '%s' "$out" | jq -c '[.projects[].name]')"
# A title always joins the project (MC3 Titles). No project known: the title alone. A card name wins.
for s in s-side s-sum s-none; do old 120 "$HOME/.claude/projects/p/$s.jsonl"; done
out="$(ex)"; [ "$(pname "$out" s-ship)" = 'Demo · ship 0.16.1' ] || fail "single session: $(pname "$out" s-ship)"   # MC3 Titles: always "<Project> · <title>"
mkdir -p "$OSRC_HOME/owners/s-loose" "$OSRC_JOBS/s-loose-job"; printf '{}\n' > "$OSRC_JOBS/s-loose-job/meta.json"; touch "$OSRC_HOME/owners/s-loose/s-loose-job"
printf '%s\n' '{"type":"user","message":{"content":"/plan draft the launch email"}}' > "$HOME/.claude/projects/p/s-loose.jsonl"
out="$(ex)"; [ "$(pname "$out" s-loose)" = 'draft the launch email' ] || fail "no-project name: $(pname "$out" s-loose)"
printf '{"name":"Launch Email"}\n' > "$OSRC_HOME/hub/projects/s-loose.json"
out="$(ex)"; [ "$(pname "$out" s-loose)" = 'Launch Email' ] || fail 'card name did not win'
rm -f "$OSRC_HOME/hub/projects/s-loose.json"
printf 'PASS: MC2 r3 names: humanized project, session detail, session N, card wins, no ids\n'

# Visibility: live lane, open decision or a fresh transcript; never a session that never delegated.
mkdir -p "$OSRC_HOME/owners/s-spam"; printf '%s\n' '{"type":"user","message":{"content":"hello"}}' > "$HOME/.claude/projects/p/s-spam.jsonl"
out="$(ex)"
shown "$out" s-ship || fail 'fresh transcript with lanes hidden'
! shown "$out" s-side || fail 'stale session with no live lane shown'
! shown "$out" s-spam || fail 'spam session (no lanes ever) shown'
! shown "$out" old-session || fail 'finished session shown'
shown "$out" live-sess || fail 'session with live tmux lanes hidden'
printf '%s' "$out" | jq -e 'any(.projects[]; .id == "unowned") | not' >/dev/null || fail 'unowned runs without a live lane shown'
printf '[{"id":"D1","q":"Ship it?","weight":"High"}]\n' > "$OSRC_HOME/hub/decisions/s-side.json"
shown "$(ex)" s-side || fail 'open decision hidden'
printf '[{"id":"D1","q":"Ship it?","status":"done"}]\n' > "$OSRC_HOME/hub/decisions/s-side.json"
! shown "$(ex)" s-side || fail 'answered decision kept a stale session'
old 10 "$HOME/.claude/projects/p/s-ship.jsonl"
shown "$(ex)" s-ship || fail '10-min-old transcript hidden at the 30-min default'
! shown "$(OSRC_HUB_ACTIVE_MIN=5 ex)" s-ship || fail 'OSRC_HUB_ACTIVE_MIN ignored'
shown "$(ex --project s-spam)" s-spam || fail '--project no longer answers for a hidden slug'
[ -d "$OSRC_HOME/owners/s-spam" ] && [ -f "$OSRC_JOBS/s-side-job/status" ] || fail 'hidden session data removed'
printf 'PASS: MC2 r3 visibility: live lane, open decision, fresh transcript; spam and finished hidden\n'
