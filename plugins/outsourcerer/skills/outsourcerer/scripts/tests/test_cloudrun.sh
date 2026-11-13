#!/usr/bin/env bash
# test_cloudrun.sh — L10 cloud-first delegation: osrc_where routing + `cloud start` lifecycle.
# OFFLINE ONLY: vehicle CLIs (claude/devin/codex/gh) are PATH stubs that log argv and print a
# fake session URL; git runs against a LOCAL bare repo standing in for the remote (no network).
# Every OSRC_* state dir is a scratch mktemp dir, cleaned by trap. No tmux is used at all.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
if [ ! -f "$SRC" ]; then echo FAIL: cannot find "$SRC"; exit 1; fi

export OSRC_HOME="${TMPDIR:-/tmp}/osrc-test-L10-home-$$"
mkdir -p "$OSRC_HOME"

. "$SRC" >/dev/null 2>&1
SCRIPT_PATH="$SRC"   # sourced mode: $0 is this harness; point preflight/self-exec at the real script

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
cleanup() { rm -rf "$TMP" "$OSRC_HOME"; }
trap cleanup EXIT

TMP="$(mktemp -d)"
export OSRC_STUB_LOG="$TMP/stub.log"; : > "$OSRC_STUB_LOG"

# ---------- stubs: claude / devin / codex / gh (log argv, fake auth, fake session URL) ----------
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
{ echo "=== claude"; printf '<%s>\n' "$@"; } >> "$OSRC_STUB_LOG"
case "${1:-}" in
  auth)   echo '{"loggedIn": true}'; exit 0 ;;
  --help|-h|help) echo "Usage: claude [options] [prompt]"; echo "  --cloud [description|session_id|url]"; echo "  --environment <environment_id>"; exit 0 ;;
  --cloud) echo "Claude session started: https://claude.ai/code/session_test123"; exit 0 ;;
esac
exit 0
EOF
cat > "$STUB/devin" <<'EOF'
#!/usr/bin/env bash
{ echo "=== devin"; printf '<%s>\n' "$@"; } >> "$OSRC_STUB_LOG"
case "${1:-}" in
  auth)   echo "Logged in (via Devin)."; exit 0 ;;
  --help|-h|help) echo "Usage: devin [options]"; echo "  --cloud"; echo "  -p, --print [<PROMPT>]"; echo "      --prompt-file <FILE>"; exit 0 ;;
  --cloud) echo "Devin session: https://app.devin.ai/sessions/devin-0123456789abcdef"; exit 0 ;;
esac
exit 0
EOF
cat > "$STUB/codex" <<'EOF'
#!/usr/bin/env bash
{ echo "=== codex"; printf '<%s>\n' "$@"; } >> "$OSRC_STUB_LOG"
case "${1:-}" in
  login)  echo "Logged in using ChatGPT"; exit 0 ;;
  cloud)
    for a in "$@"; do [ "$a" = "--help" ] && { echo "codex cloud exec [OPTIONS] [QUERY]"; echo "  --env <ENV_ID>"; echo "  --branch <BRANCH>"; exit 0; }; done
    echo "Codex task started: https://chatgpt.com/codex/tasks/task_cloudrun1"; exit 0 ;;
esac
exit 0
EOF
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
{ echo "=== gh"; printf '<%s>\n' "$@"; } >> "$OSRC_STUB_LOG"
echo "gh stub: not implemented" >&2; exit 1
EOF
chmod +x "$STUB"/*

# ---------- fake remote + working clone (all local, zero network) ----------
BARE="$TMP/origin.git"; WORK="$TMP/work"
git init --bare "$BARE" >/dev/null 2>&1
git init "$WORK" >/dev/null 2>&1
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name test
printf 'hello\n' > "$WORK/README.md"
git -C "$WORK" add -A && git -C "$WORK" commit -qm init
git -C "$WORK" branch -M main
git -C "$WORK" remote add origin "$BARE"
git -C "$WORK" push -qu origin main

BRIEF="$TMP/brief.md"
printf 'Add a /healthz endpoint returning {"ok":true} and a unit test for it.\n' > "$BRIEF"
BRIEF_LOCAL="$TMP/brief-local.md"
printf 'Pull the latest WhatsApp chat export and summarize it into the report.\n' > "$BRIEF_LOCAL"
BRIEF_SECRET="$TMP/brief-secret.md"
printf 'Use this key to call the API: sk-abcdef1234567890abcdef\n' > "$BRIEF_SECRET"
BRIEF_PRIVATE="$TMP/brief-private.md"
printf 'Read the notes in /Users/someone/private/plan.md and implement them.\n' > "$BRIEF_PRIVATE"

export CLAUDE_CODE_SESSION_ID="test-L10-session"
export OSRC_CLOUD_ACK=1 OSRC_CLOUD_LAUNCH_WAIT=8

start_cloud() { # runs _cloudrun_start inside WORK with stubs on PATH; args passed through
  ( cd "$WORK" && PATH="$STUB:$PATH" _cloudrun_start "$@" )
}

# ============================== osrc_where routing table ==============================
w() { osrc_where "$1" | head -1; }
[ "$(w 'refactor the auth module and add unit tests')" = "cloud" ] \
  && ok "where: self-contained repo work -> cloud" || bad "where: repo work not cloud"
[ "$(w 'install the new npm packages and run the full test suite')" = "cloud" ] \
  && ok "where: install+heavy tests -> cloud" || bad "where: heavy work not cloud"
[ "$(w 'audit this third-party dependency for security issues')" = "cloud" ] \
  && ok "where: untrusted/external work -> cloud" || bad "where: untrusted work not cloud"
[ "$(w 'summarize the whatsapp chat export')" = "local" ] \
  && ok "where: whatsapp -> local" || bad "where: whatsapp not local"
[ "$(w 'restart postgres and run the migrations')" = "local" ] \
  && ok "where: local DB -> local" || bad "where: local db not local"
[ "$(w 'keep this local, do not use cloud')" = "local" ] \
  && ok "where: explicit local -> local" || bad "where: explicit local not local"
[ "$(w 'continue my work on the current branch')" = "cloud" ] \
  && ok "where: current-branch w/o unpushed -> cloud" || bad "where: current-branch misrouted"
[ "$(w '')" = "local" ] && ok "where: empty brief -> local" || bad "where: empty brief not local"
# file input form
[ "$(osrc_where "$BRIEF_LOCAL" | head -1)" = "local" ] \
  && ok "where: brief FILE input -> local" || bad "where: file input misrouted"
# reason line present
osrc_where 'summarize whatsapp' | sed -n '2p' | grep -q '^reason: ' \
  && ok "where: reason line emitted" || bad "where: missing reason line"

# unpushed-commit routing: commit locally (not pushed) then re-check
( cd "$WORK" && git commit -qm wip --allow-empty )
[ "$(cd "$WORK" && osrc_where 'continue my work on the current branch' | head -1)" = "local" ] \
  && ok "where: unpushed commits + current branch -> local" || bad "where: unpushed not detected"
git -C "$WORK" reset -q --hard HEAD~1

# cloud where subcommand goes through cmd_cloud dispatch
cmd_cloud where 'refactor the parser' | head -1 | grep -qx 'cloud' \
  && ok "cloud where: dispatch -> cloud" || bad "cloud where: dispatch failed"

# ============================== preflight: unpushed refusal ==============================
( cd "$WORK" && git commit -qm wip --allow-empty )
out="$(start_cloud t-unpushed --repo "$WORK" --base main --brief "$BRIEF" --vehicle claude 2>&1)"; rc=$?
git -C "$WORK" reset -q --hard HEAD~1
[ $rc -ne 0 ] && ok "preflight: unpushed commits refuse (rc=$rc)" || bad "preflight: unpushed commits allowed"
echo "$out" | grep -q 'not on ANY remote ref' && ok "preflight: refusal names unpushed commits" \
  || bad "preflight: refusal message missing"
echo "$out" | grep -q 'wip' && ok "preflight: refusal lists the commit" || bad "preflight: commit not listed"
[ ! -e "$OSRC_HOME/remote/t-unpushed.json" ] && ok "preflight: no lane registered on refusal" \
  || bad "preflight: lane json written despite refusal"

# missing base branch on the remote
out="$(start_cloud t-nobranch --repo "$WORK" --base no-such-branch --brief "$BRIEF" --vehicle claude 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "does not exist on the remote" \
  && ok "preflight: missing remote base refuses" || bad "preflight: missing base not refused (rc=$rc)"

# ============================== pack gates: secret + private =============================
out="$(start_cloud t-secret --repo "$WORK" --base main --brief "$BRIEF_SECRET" --vehicle claude 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'live secret VALUE' \
  && ok "gate: secret value in brief -> CLOUD GATE refusal" || bad "gate: secret value NOT refused (rc=$rc)"

out="$(start_cloud t-private --repo "$WORK" --base main --brief "$BRIEF_PRIVATE" --where cloud --vehicle claude 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'PRIVATE PATH' \
  && ok "gate: machine-local path in brief -> private check refusal" || bad "gate: private path NOT refused (rc=$rc)"

# denylist file path
printf 'healthz\n' > "$OSRC_HOME/cloud-private-names.txt"
out="$(start_cloud t-deny --repo "$WORK" --base main --brief "$BRIEF" --where cloud --vehicle claude 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'PRIVATE NAME' \
  && ok "gate: denylisted name -> refusal" || bad "gate: denylist NOT enforced (rc=$rc)"
rm -f "$OSRC_HOME/cloud-private-names.txt"

# ============================== --where routing at start =============================
out="$(start_cloud t-where --repo "$WORK" --base main --brief "$BRIEF_LOCAL" --vehicle claude 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'routed this brief LOCAL' \
  && ok "start: --where auto routes local brief away" || bad "start: local brief not routed away (rc=$rc)"

out="$(start_cloud t-where2 --repo "$WORK" --base main --brief "$BRIEF" --where local --vehicle claude 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'cannot run a local brief' \
  && ok "start: --where local is a usage error" || bad "start: --where local accepted (rc=$rc)"

# ============================== consent gate ==========================================
rm -f "$OSRC_HOME/cloud-consent"
out="$( cd "$WORK" && PATH="$STUB:$PATH" bash -c '
  unset OSRC_CLOUD_ACK
  . "'"$SRC"'" >/dev/null 2>&1
  SCRIPT_PATH="'"$SRC"'"
  _cloudrun_start t-consent --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle claude
' </dev/null 2>&1 )"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'ONE-TIME consent' \
  && ok "consent: no ack + non-interactive -> refuse" || bad "consent: proceeded without ack (rc=$rc)"
[ ! -e "$OSRC_HOME/remote/t-consent.json" ] && ok "consent: no lane on refusal" || bad "consent: lane written on refusal"

# ============================== vehicle probes ========================================
# all vehicles missing -> auto refuses with reasons
out="$( cd "$WORK" && OSRC_CLOUD_ACK=1 bash -c '
  source "'"$SRC"'" >/dev/null 2>&1
  have() { case "$1" in claude|devin|codex) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  SCRIPT_PATH="'"$SRC"'"; OSRC_HOME="'"$OSRC_HOME"'"
  _cloudrun_start t-noveh --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle auto
' 2>&1 )"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'no usable hosted-session vehicle' \
  && ok "vehicle: all missing -> auto refuses" || bad "vehicle: all-missing not refused (rc=$rc)"

# claude missing -> auto skips to devin
out="$( cd "$WORK" && OSRC_CLOUD_ACK=1 OSRC_CLOUD_LAUNCH_WAIT=8 bash -c '
  source "'"$SRC"'" >/dev/null 2>&1
  have() { case "$1" in claude) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  SCRIPT_PATH="'"$SRC"'"; OSRC_HOME="'"$OSRC_HOME"'"; OSRC_STUB_LOG="'"$OSRC_STUB_LOG"'"
  PATH="'"$STUB"':$PATH" _cloudrun_start t-skip --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle auto
' 2>&1 )"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'devin session started' \
  && ok "vehicle: missing claude -> auto skips to devin" || bad "vehicle: skip-to-devin failed (rc=$rc)"
echo "$out" | grep -q 'vehicle skipped' && ok "vehicle: skip reason printed" || bad "vehicle: skip reason missing"

# ============================== launch argv per vehicle ===============================
: > "$OSRC_STUB_LOG"
out="$(start_cloud t-claude --repo "$WORK" --base main --brief "$BRIEF" --vehicle claude --claude-env ccpool-1 --model sonnet-test 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "launch: claude start rc=0" || { bad "launch: claude rc=$rc"; echo "$out"; }
sec="$(awk '/=== claude/{f=1;next}/=== /{f=0}f' "$OSRC_STUB_LOG")"
echo "$sec" | grep -qx -- '<--cloud>' && ok "launch: claude argv has --cloud" || bad "launch: claude --cloud missing"
echo "$sec" | grep -q 'ccpool-1' && ok "launch: claude --environment passed" || bad "launch: --environment missing"
echo "$sec" | grep -q 'sonnet-test' && ok "launch: claude --model passed" || bad "launch: --model missing"
echo "$sec" | grep -q 'cloud/t-claude' && ok "launch: pack names work branch cloud/<id>" || bad "launch: pack missing branch"
echo "$sec" | grep -q 't-claude.READY' && ok "launch: pack carries READY contract" || bad "launch: pack missing READY"
[ -f "$OSRC_HOME/remote/t-claude.json" ] && ok "lane: remote/t-claude.json registered" || bad "lane: json missing"
jq -r '.vehicle // empty' "$OSRC_HOME/remote/t-claude.json" 2>/dev/null | grep -qx 'claude' \
  && ok "lane: vehicle field = claude" || bad "lane: vehicle field wrong"
jq -r '.session_ref // empty' "$OSRC_HOME/remote/t-claude.json" 2>/dev/null | grep -q 'claude.ai' \
  && ok "lane: session_ref captured from launch log" || bad "lane: session_ref missing"
jq -r '.branch // empty' "$OSRC_HOME/remote/t-claude.json" 2>/dev/null | grep -qx 'cloud/t-claude' \
  && ok "lane: branch = cloud/t-claude" || bad "lane: branch wrong"
[ -f "$OSRC_HOME/owners/test-L10-session/t-claude" ] && ok "owner: owner record written" || bad "owner: record missing"
echo "$out" | grep -q 'Claude subscription' && ok "quota: claude plan disclosed" || bad "quota: claude plan missing"
echo "$out" | grep -q 'session:' && ok "output: session ref printed" || bad "output: session ref missing"

: > "$OSRC_STUB_LOG"
out="$(start_cloud t-devin --repo "$WORK" --base main --brief "$BRIEF" --vehicle devin 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "launch: devin start rc=0" || { bad "launch: devin rc=$rc"; echo "$out"; }
sec="$(awk '/=== devin/{f=1;next}/=== /{f=0}f' "$OSRC_STUB_LOG")"
echo "$sec" | grep -qx -- '<--cloud>' && echo "$sec" | grep -qx -- '<-p>' && echo "$sec" | grep -q -- '--prompt-file' \
  && ok "launch: devin argv = --cloud -p --prompt-file" || bad "launch: devin argv wrong"
pf="$(echo "$sec" | grep -A1 -- '--prompt-file' | sed -n '2p' | tr -d '<>')"
[ -n "$pf" ] && [ -f "$pf" ] && grep -q 'cloud/t-devin' "$pf" \
  && ok "launch: devin prompt-file is the context pack" || bad "launch: prompt-file wrong ($pf)"
jq -r '.vehicle' "$OSRC_HOME/remote/t-devin.json" 2>/dev/null | grep -qx 'devin' \
  && ok "lane: devin vehicle recorded" || bad "lane: devin vehicle wrong"

: > "$OSRC_STUB_LOG"
out="$(start_cloud t-codex --repo "$WORK" --base main --brief "$BRIEF" --vehicle codex --env env-test-9 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "launch: codex start rc=0" || { bad "launch: codex rc=$rc"; echo "$out"; }
sec="$(awk '/=== codex/{f=1;next}/=== /{f=0}f' "$OSRC_STUB_LOG")"
echo "$sec" | grep -qx -- '<cloud>' && echo "$sec" | grep -qx -- '<exec>' && echo "$sec" | grep -q -- '<--env>' \
  && ok "launch: codex argv = cloud exec --env" || bad "launch: codex argv wrong"
echo "$sec" | grep -q 'env-test-9' && echo "$sec" | grep -qx -- '<--branch>' && echo "$sec" | grep -qx -- '<main>' \
  && ok "launch: codex env id + branch passed" || bad "launch: codex env/branch missing"
echo "$out" | grep -q 'Codex plan' && ok "quota: codex plan disclosed" || bad "quota: codex plan missing"

# codex without env id -> refused
out="$(start_cloud t-codexnoenv --repo "$WORK" --base main --brief "$BRIEF" --vehicle codex 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'environment id' \
  && ok "codex: missing --env refuses with reason" || bad "codex: missing env not refused (rc=$rc)"

# ============================== registration hooks =====================================
# L2 present: stub cmd_lane -> it is called with the lane-add contract
out="$( cd "$WORK" && OSRC_CLOUD_ACK=1 OSRC_CLOUD_LAUNCH_WAIT=8 bash -c '
  source "'"$SRC"'" >/dev/null 2>&1
  cmd_lane() { printf "LANEADD|%s\n" "$*" >> "'"$OSRC_STUB_LOG"'"; return 0; }
  SCRIPT_PATH="'"$SRC"'"; OSRC_HOME="'"$OSRC_HOME"'"
  PATH="'"$STUB"':$PATH" _cloudrun_start t-l2 --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle devin --done-when "check:npm test"
' 2>&1 )"; rc=$?
[ $rc -eq 0 ] && grep -q 'LANEADD|add t-l2 --branch cloud/t-l2' "$OSRC_STUB_LOG" \
  && ok "register: cmd_lane lane add invoked with contract args" || bad "register: cmd_lane not called (rc=$rc)"
grep 'LANEADD' "$OSRC_STUB_LOG" | grep -q -- '--ready READY' && grep 'LANEADD' "$OSRC_STUB_LOG" | grep -q -- '--done-when check:npm test' \
  && ok "register: ready marker + done-when forwarded" || bad "register: lane args incomplete"

# ============================== conserve mode -> devin preferred =====================
# (a) lane-posture down marker on the claude-native lane (key cc)
mkdir -p "$OSRC_HOME/lane-posture"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$OSRC_HOME/lane-posture/cc.down"
out="$(start_cloud t-conserve --repo "$WORK" --base main --brief "$BRIEF" --vehicle auto 2>&1)"; rc=$?
rm -f "$OSRC_HOME/lane-posture/cc.down"
[ $rc -eq 0 ] && echo "$out" | grep -q 'devin session started' \
  && ok "conserve: lane-posture cc.down -> auto picks devin" || bad "conserve: posture marker ignored (rc=$rc): $out"

# (b) session-limit pressure at/over the conserve line
out="$( cd "$WORK" && OSRC_CLOUD_ACK=1 OSRC_CLOUD_LAUNCH_WAIT=8 OSRC_CC_PRESSURE=80 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  SCRIPT_PATH="'"$SRC"'"
  PATH="'"$STUB"':$PATH" _cloudrun_start t-conserve2 --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle auto
' 2>&1 )"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'devin session started' \
  && ok "conserve: claude window >= threshold -> auto picks devin" || bad "conserve: pressure ignored (rc=$rc): $out"

# L6 present: stub osrc_done_set -> called with a check: spec + cwd
: > "$OSRC_STUB_LOG"
out="$( cd "$WORK" && OSRC_CLOUD_ACK=1 OSRC_CLOUD_LAUNCH_WAIT=8 bash -c '
  source "'"$SRC"'" >/dev/null 2>&1
  osrc_done_set() { printf "DONESET|%s|%s|%s\n" "$1" "$2" "$3" >> "'"$OSRC_STUB_LOG"'"; return 0; }
  SCRIPT_PATH="'"$SRC"'"; OSRC_HOME="'"$OSRC_HOME"'"
  PATH="'"$STUB"':$PATH" _cloudrun_start t-l6 --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle devin
' 2>&1 )"; rc=$?
[ $rc -eq 0 ] && grep -q 'DONESET|t-l6|check:bash ' "$OSRC_STUB_LOG" \
  && ok "done contract: osrc_done_set invoked" || bad "done contract: osrc_done_set not called (rc=$rc)"
done_script="$(grep 'DONESET|t-l6' "$OSRC_STUB_LOG" | cut -d'|' -f3 | sed 's/^check:bash //')"
[ -n "$done_script" ] && [ -x "$done_script" ] && grep -q 'cloud/t-l6' "$done_script" \
  && ok "done contract: generated check script verifies cloud/<id> + READY" || bad "done contract: check script bad ($done_script)"

# neither helper: still registers the lane json + prints the degrade notes
out="$(start_cloud t-bare --repo "$WORK" --base main --brief "$BRIEF" --vehicle devin 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ -f "$OSRC_HOME/remote/t-bare.json" ] \
  && ok "register: fallback json written when helpers absent" || bad "register: fallback failed (rc=$rc)"
echo "$out" | grep -q 'osrc_done_set not merged yet' \
  && ok "done contract: absent-helper note printed" || bad "done contract: missing degrade note"

# duplicate id refuses
out="$(start_cloud t-bare --repo "$WORK" --base main --brief "$BRIEF" --vehicle devin 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'already registered' \
  && ok "register: duplicate lane id refused" || bad "register: duplicate id allowed (rc=$rc)"

# ============================== cloud ls ==============================================
lsout="$(cmd_cloud ls 2>/dev/null)"
echo "$lsout" | grep -qE 't-claude[[:space:]]+claude' \
  && ok "cloud ls: lists registered lanes with vehicle" || bad "cloud ls: missing lanes"

# ============================== symlink loader ========================================
ln -s "$SRC" "$TMP/osrc-link"
link_out="$(OSRC_HOME="$OSRC_HOME" "$TMP/osrc-link" cloud where 'refactor the auth module' 2>&1)"; lrc=$?
[ $lrc -eq 0 ] && echo "$link_out" | head -1 | grep -qx 'cloud' \
  && ok "loader: symlink invocation resolves lib functions" || bad "loader: symlink dispatch failed (rc=$lrc): $link_out"
link_out="$(OSRC_HOME="$OSRC_HOME" "$TMP/osrc-link" cloud ls 2>&1)"; lrc=$?
echo "$link_out" | grep -q 't-claude' \
  && ok "loader: symlink cloud ls works" || bad "loader: symlink cloud ls failed (rc=$lrc)"

echo
echo "=== $pass passed, $fail failed ==="
[ $fail -eq 0 ]
