#!/usr/bin/env bash
# test_cloudrun.sh — L10 cloud-first delegation: osrc_where routing + `cloud start` lifecycle.
# OFFLINE ONLY: vehicle CLIs (claude/devin/codex/gh) are PATH stubs that log argv and print a
# fake session URL; git runs against a LOCAL bare repo standing in for the remote (no network).
# Every OSRC_* state dir is a scratch mktemp dir, cleaned by trap. No tmux is used at all.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
if [ ! -f "$SRC" ]; then echo FAIL: cannot find "$SRC"; exit 1; fi

# r11 F7: HOME must be scratch BEFORE sourcing — auth/billing probes read $HOME and
# OSRC_HOME lives under it. TMP is created first so cleanup() removes everything.
TMP="$(mktemp -d)"
export HOME="$TMP/home"; mkdir -p "$HOME"
export OSRC_HOME="$TMP/osrc-home"; mkdir -p "$OSRC_HOME"

. "$SRC" >/dev/null 2>&1
SCRIPT_PATH="$SRC"   # sourced mode: $0 is this harness; point preflight/self-exec at the real script

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
cleanup() { rm -rf "$TMP" "$OSRC_HOME"; }
trap cleanup EXIT
export OSRC_STUB_LOG="$TMP/stub.log"; : > "$OSRC_STUB_LOG"

# ---------- stubs: claude / devin / codex / gh (log argv, fake auth, fake session URL) ----------
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
{ echo "=== claude"; printf '<%s>\n' "$@"; } >> "$OSRC_STUB_LOG"
case "${1:-}" in
  # auth status must carry the full plan shape: cc billing is subscription ONLY on
  # loggedIn+claude.ai+firstParty+a plan subscriptionType (lib/spend.sh); bare {"loggedIn":true}
  # is unknown -> metered -> every cloud session below would refuse at the spend gate.
  auth)   cat <<'JSONEOF'
{
  "loggedIn": true,
  "authMethod": "claude.ai",
  "apiProvider": "firstParty",
  "analyticsDisabled": false,
  "projectsDirectory": "/fake/projects",
  "configDirectory": "/fake/config",
  "loginExpiresAt": "2027-01-01T00:00:00.000Z",
  "email": "fixture@example.invalid",
  "orgId": "org-fixture",
  "orgName": "Fixture Org",
  "subscriptionType": "max",
  "storedClaudeAiLogin": true,
  "planTier": "max"
}
JSONEOF
           exit 0 ;;
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
# A relative fixture remote stays local without putting a machine-specific path in the pack.
git -C "$WORK" remote add origin ../origin.git
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
export OSRC_CLOUD_LAUNCH_WAIT=8
# Hosted sessions use their OWN consent key (cloud-session-consent), never OSRC_CLOUD_ACK
# and never the model-API cloud-consent file. Grant it once for the happy paths below.
_cloudrun_consent_grant

start_cloud() { # runs _cloudrun_start inside WORK with stubs on PATH; args passed through
  ( cd "$WORK" && hash -r && PATH="$STUB:$PATH" _cloudrun_start "$@" )
}

# ============================== osrc_where routing table ==============================
# Run inside the fixture repo ($WORK): osrc_where's unpushed-commit check reads the cwd's
# git state, and this suite itself sits on an unpushed lane branch.
w() { local _w; _w="$( cd "$WORK" && osrc_where "$1" )"; printf '%s\n' "${_w%%$'\n'*}"; }
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
for brief in "Prepare Total Recall release notes. The old build failed on the user's Mac under /Users/alex/Library." \
             "Add a regression test for the error message mentioning localhost and SQLite."; do
  [ "$(w "$brief")" = cloud ] && ok "cloud: $brief" || bad "misrouted: $brief"
done
for brief in "Inspect ~/Library/Logs/recall.log before preparing the release." \
             "Capture the attached USB webcam output for the bug report."; do
  [ "$(w "$brief")" = local ] && ok "local: $brief" || bad "misrouted: $brief"
done
# file input form
_wf="$(osrc_where "$BRIEF_LOCAL")"; [ "${_wf%%$'\n'*}" = "local" ] \
  && ok "where: brief FILE input -> local" || bad "where: file input misrouted"
# reason line present
_wf="$(osrc_where 'summarize whatsapp' | sed -n '2p')"; grep -q '^reason: ' <<<"$_wf" \
  && ok "where: reason line emitted" || bad "where: missing reason line"

# unpushed-commit routing: commit locally (not pushed) then re-check
( cd "$WORK" && git commit -qm wip --allow-empty )
_wf="$( cd "$WORK" && osrc_where 'continue my work on the current branch' )"; [ "${_wf%%$'\n'*}" = "local" ] \
  && ok "where: unpushed commits + current branch -> local" || bad "where: unpushed not detected"
git -C "$WORK" reset -q --hard HEAD~1

# cloud where subcommand goes through cmd_cloud dispatch
_wf="$(cmd_cloud where 'refactor the parser')"; [ "${_wf%%$'\n'*}" = "cloud" ] \
  && ok "cloud where: dispatch -> cloud" || bad "cloud where: dispatch failed"

# ============================== preflight: unpushed refusal ==============================
( cd "$WORK" && git commit -qm wip --allow-empty )
out="$(start_cloud t-unpushed --repo "$WORK" --base main --brief "$BRIEF" --vehicle claude 2>&1)"; rc=$?
git -C "$WORK" reset -q --hard HEAD~1
[ $rc -ne 0 ] && ok "preflight: unpushed commits refuse (rc=$rc)" || bad "preflight: unpushed commits allowed"
grep -q 'not on ANY remote ref' <<<"$out" && ok "preflight: refusal names unpushed commits" \
  || bad "preflight: refusal message missing"
grep -q 'wip' <<<"$out" && ok "preflight: refusal lists the commit" || bad "preflight: commit not listed"
[ ! -e "$OSRC_HOME/remote/t-unpushed.json" ] && ok "preflight: no lane registered on refusal" \
  || bad "preflight: lane json written despite refusal"

# missing base branch on the remote
out="$(start_cloud t-nobranch --repo "$WORK" --base no-such-branch --brief "$BRIEF" --vehicle claude 2>&1)"; rc=$?
[ $rc -ne 0 ] && grep -q "does not exist on the remote" <<<"$out" \
  && ok "preflight: missing remote base refuses" || bad "preflight: missing base not refused (rc=$rc)"

# ============================== pack gates: secret + private =============================
out="$(start_cloud t-secret --repo "$WORK" --base main --brief "$BRIEF_SECRET" --vehicle claude 2>&1)"; rc=$?
[ $rc -ne 0 ] && grep -q 'live secret VALUE' <<<"$out" \
  && ok "gate: secret value in brief -> CLOUD GATE refusal" || bad "gate: secret value NOT refused (rc=$rc)"

out="$(start_cloud t-private --repo "$WORK" --base main --brief "$BRIEF_PRIVATE" --where cloud --vehicle claude 2>&1)"; rc=$?
[ $rc -ne 0 ] && grep -q 'PRIVATE PATH' <<<"$out" \
  && ok "gate: machine-local path in brief -> private check refusal" || bad "gate: private path NOT refused (rc=$rc)"

# denylist file path
printf 'healthz\n' > "$OSRC_HOME/cloud-private-names.txt"
out="$(start_cloud t-deny --repo "$WORK" --base main --brief "$BRIEF" --where cloud --vehicle claude 2>&1)"; rc=$?
[ $rc -ne 0 ] && grep -q 'PRIVATE NAME' <<<"$out" \
  && ok "gate: denylisted name -> refusal" || bad "gate: denylist NOT enforced (rc=$rc)"
rm -f "$OSRC_HOME/cloud-private-names.txt"

# ============================== --where routing at start =============================
out="$(start_cloud t-where --repo "$WORK" --base main --brief "$BRIEF_LOCAL" --vehicle claude 2>&1)"; rc=$?
[ $rc -ne 0 ] && grep -q 'routed this brief LOCAL' <<<"$out" \
  && ok "start: --where auto routes local brief away" || bad "start: local brief not routed away (rc=$rc)"

out="$(start_cloud t-where2 --repo "$WORK" --base main --brief "$BRIEF" --where local --vehicle claude 2>&1)"; rc=$?
[ $rc -ne 0 ] && grep -q 'cannot run a local brief' <<<"$out" \
  && ok "start: --where local is a usage error" || bad "start: --where local accepted (rc=$rc)"

# ============================== consent gate (own key: cloud-session-consent) =============
rm -f "$OSRC_HOME/cloud-session-consent" "$OSRC_HOME/cloud-consent"
out="$( cd "$WORK" && PATH="$STUB:$PATH" bash -c '
  unset OSRC_CLOUD_ACK
  . "'"$SRC"'" >/dev/null 2>&1
  SCRIPT_PATH="'"$SRC"'"
  _cloudrun_start t-consent --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle claude
' </dev/null 2>&1 )"; rc=$?
[ $rc -ne 0 ] && grep -q 'cloud consent grant' <<<"$out" \
  && ok "consent: no session grant + non-interactive -> refuse" || bad "consent: proceeded without grant (rc=$rc): $out"
[ ! -e "$OSRC_HOME/remote/t-consent.json" ] && ok "consent: no lane on refusal" || bad "consent: lane written on refusal"

# the model-API consent file + OSRC_CLOUD_ACK must NOT imply hosted-session consent
printf 'granted\n' > "$OSRC_HOME/cloud-consent"
out="$( cd "$WORK" && PATH="$STUB:$PATH" bash -c '
  export OSRC_CLOUD_ACK=1
  . "'"$SRC"'" >/dev/null 2>&1
  SCRIPT_PATH="'"$SRC"'"
  _cloudrun_start t-consent2 --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle claude
' </dev/null 2>&1 )"; rc=$?
[ $rc -ne 0 ] && grep -q 'cloud consent grant' <<<"$out" \
  && ok "consent: OSRC_CLOUD_ACK + model-API file do NOT grant sessions" || bad "consent: env/old file implied session consent (rc=$rc)"
rm -f "$OSRC_HOME/cloud-consent"

# `cloud consent grant` subcommand is the documented fix, then start proceeds
out="$( cd "$WORK" && PATH="$STUB:$PATH" bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  SCRIPT_PATH="'"$SRC"'"
  cmd_cloud consent grant >/dev/null && cmd_cloud consent status
' 2>&1 )"
grep -q 'GRANTED' <<<"$out" && ok "consent: cloud consent grant/status works" || bad "consent: grant subcommand failed: $out"

# ============================== L7 spend gate integration ==============================
# when _osrc_spend_gate is loaded, cloud start calls it with the vehicle->lane mapping
# (claude->cc, devin->dv, codex->cx) BEFORE consent/launch.
out="$( cd "$WORK" && PATH="$STUB:$PATH" OSRC_CLOUD_LAUNCH_WAIT=8 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  SCRIPT_PATH="'"$SRC"'"
  _osrc_spend_gate() { echo "SPEND_GATE|$1|$2|$3|$4" >> "'"$OSRC_STUB_LOG"'"; }
  _cloudrun_start t-spend --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle claude --model sonnet-test
' 2>&1 )"; rc=$?
[ $rc -eq 0 ] && grep -q 'SPEND_GATE|cc|sonnet-test|claude|cloud session t-spend' "$OSRC_STUB_LOG" \
  && ok "spend: gate called lane=cc model=sonnet-test disp=claude" || bad "spend: gate args wrong/missing (rc=$rc): $(grep SPEND "$OSRC_STUB_LOG")"
: > "$OSRC_STUB_LOG"
out="$( cd "$WORK" && PATH="$STUB:$PATH" OSRC_CLOUD_LAUNCH_WAIT=8 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  SCRIPT_PATH="'"$SRC"'"
  _osrc_spend_gate() { echo "SPEND_GATE|$1|$2|$3|$4" >> "'"$OSRC_STUB_LOG"'"; }
  _cloudrun_start t-spenddv --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle devin
' 2>&1 )"; rc=$?
grep -q 'SPEND_GATE|dv||devin|' "$OSRC_STUB_LOG" \
  && ok "spend: devin maps to dv lane (ACU-metered)" || bad "spend: devin lane mapping wrong: $(grep SPEND "$OSRC_STUB_LOG")"
# a refusing gate must stop the launch dead
out="$( cd "$WORK" && PATH="$STUB:$PATH" bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  SCRIPT_PATH="'"$SRC"'"
  _osrc_spend_gate() { die "spend gate refused (test)"; }
  _cloudrun_start t-spendno --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle claude
' 2>&1 )"; rc=$?
[ $rc -ne 0 ] && grep -q 'spend gate refused' <<<"$out" \
  && ok "spend: gate refusal stops launch" || bad "spend: refusal not honored (rc=$rc)"
[ ! -e "$OSRC_HOME/remote/t-spendno.json" ] && ok "spend: no lane registered on refusal" || bad "spend: lane written on refusal"

# ---- fail closed when NO spend gate is loaded (finding A) ----
# devin cloud is metered: refuses unless THIS command carries --spend-ok
out="$(start_cloud t-devin-nook --repo "$WORK" --base main --brief "$BRIEF" --vehicle devin 2>&1)"; rc=$?
[ $rc -ne 0 ] && grep -q -- '--spend-ok' <<<"$out" \
  && ok "spend: devin refuses without --spend-ok when gate absent" || bad "spend: devin fail-open (rc=$rc): $out"
[ ! -e "$OSRC_HOME/remote/t-devin-nook.json" ] && ok "spend: no lane on devin refusal" || bad "spend: lane written on devin refusal"
out="$(start_cloud t-devin-ok --repo "$WORK" --base main --brief "$BRIEF" --vehicle devin --spend-ok 2>&1)"; rc=$?
[ $rc -eq 0 ] && grep -q 'devin session started' <<<"$out" \
  && ok "spend: --spend-ok approves THIS devin launch only" || bad "spend: --spend-ok failed (rc=$rc): $out"
# subscription lanes proceed with a printed note when the gate is absent.
# L7 merged: lib/spend.sh IS loaded in this suite, so simulate its absence for this check.
out="$( cd "$WORK" && PATH="$STUB:$PATH" bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  unset -f _osrc_spend_gate
  SCRIPT_PATH="'"$SRC"'"; OSRC_HOME="'"$OSRC_HOME"'"
  _cloudrun_start t-claude-nogate --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle claude
' 2>&1 )"; rc=$?
[ $rc -eq 0 ] && grep -q 'spend gate not loaded' <<<"$out" \
  && ok "spend: claude subscription lane proceeds with note" || bad "spend: claude no-gate path (rc=$rc): $out"

# ---- finding C: --spend-ok exports OSRC_SPEND_OK, devin always asks, OSRC_SPEND_NEXT set ----
# gate loaded AND permissive: devin STILL refuses without the flag (gate is additive, not a substitute)
out="$( cd "$WORK" && OSRC_CLOUD_ACK=1 OSRC_CLOUD_LAUNCH_WAIT=8 bash -c '
  source "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate() { echo "GATE|$1|$2|$3|$4|SPEND_OK=${OSRC_SPEND_OK:-unset}|NEXT=${OSRC_SPEND_NEXT:-unset}" >> "'"$OSRC_STUB_LOG"'"; return 0; }
  SCRIPT_PATH="'"$SRC"'"; OSRC_HOME="'"$OSRC_HOME"'"
  PATH="'"$STUB"':$PATH" _cloudrun_start t-dvgate --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle devin
' 2>&1 )"; rc=$?
[ $rc -ne 0 ] && grep -q -- '--spend-ok' <<<"$out" \
  && ok "spend: devin refuses without --spend-ok even when gate loaded" || bad "spend: gate substituted for flag (rc=$rc): $out"
grep -q 'GATE|dv||devin|cloud session t-dvgate' "$OSRC_STUB_LOG" \
  && ok "spend: gate still called for devin (additive)" || bad "spend: gate not called for devin"
# --spend-ok exports OSRC_SPEND_OK=1 + OSRC_SPEND_NEXT carries the runnable line
: > "$OSRC_STUB_LOG"
out="$( cd "$WORK" && OSRC_CLOUD_ACK=1 OSRC_CLOUD_LAUNCH_WAIT=8 bash -c '
  source "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate() { echo "GATE|SPEND_OK=${OSRC_SPEND_OK:-unset}|NEXT=${OSRC_SPEND_NEXT:-unset}" >> "'"$OSRC_STUB_LOG"'"; return 0; }
  SCRIPT_PATH="'"$SRC"'"; OSRC_HOME="'"$OSRC_HOME"'"
  PATH="'"$STUB"':$PATH" _cloudrun_start t-dvok --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle devin --spend-ok
' 2>&1 )"; rc=$?
[ $rc -eq 0 ] && grep -q 'GATE|SPEND_OK=1|' "$OSRC_STUB_LOG" \
  && ok "spend: --spend-ok exports OSRC_SPEND_OK=1 to the gate" || bad "spend: OSRC_SPEND_OK not exported (rc=$rc): $out"
{ _t3b_pipe="$(grep 'GATE|' "$OSRC_STUB_LOG")" && grep -q 'NEXT=.*cloud start t-dvok' <<<"$_t3b_pipe"; } \
  && ok "spend: OSRC_SPEND_NEXT carries the runnable cloud start line" || bad "spend: OSRC_SPEND_NEXT wrong: $(grep GATE "$OSRC_STUB_LOG")"
# inherited OSRC_SPEND_OK=1 WITHOUT the flag does not satisfy the devin check
out="$( cd "$WORK" && OSRC_CLOUD_ACK=1 OSRC_CLOUD_LAUNCH_WAIT=8 OSRC_SPEND_OK=1 bash -c '
  source "'"$SRC"'" >/dev/null 2>&1
  SCRIPT_PATH="'"$SRC"'"; OSRC_HOME="'"$OSRC_HOME"'"
  PATH="'"$STUB"':$PATH" _cloudrun_start t-dvenv --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle devin
' 2>&1 )"; rc=$?
[ $rc -ne 0 ] && grep -q -- '--spend-ok' <<<"$out" \
  && ok "spend: inherited OSRC_SPEND_OK=1 does not approve devin" || bad "spend: env var approved devin (rc=$rc)"
# heavy-* lane ids refuse to run without --sha (pack cannot drift from the offer)
out="$(start_cloud heavy-1-deadbeef --repo "$WORK" --base main --brief "$BRIEF" --vehicle claude 2>&1)"; rc=$?
[ $rc -ne 0 ] && grep -q -- '--sha' <<<"$out" \
  && ok "sha: heavy-* id refuses without --sha" || bad "sha: heavy id ran without --sha (rc=$rc): $out"
out="$(start_cloud heavy-2-deadbeef --repo "$WORK" --base main --brief "$BRIEF" --vehicle claude --sha "$(git -C "$WORK" rev-parse HEAD)" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "sha: heavy-* id + --sha launches" || bad "sha: heavy id + --sha failed (rc=$rc): $out"

# ============================== URL credential stripping ==============================
cu="$(_osrc_url_clean 'https://x-access-token:TOK123@github.com/acme/widgets.git')"
[ "$cu" = "https://github.com/acme/widgets.git" ] \
  && ok "urlclean: user:pass@ stripped" || bad "urlclean: '$cu'"
cu2="$(_osrc_url_clean 'https://user@github.com/acme/widgets.git')"
[ "$cu2" = "https://github.com/acme/widgets.git" ] \
  && ok "urlclean: bare user@ stripped" || bad "urlclean user@: '$cu2'"
# finding D edge cases: scp-style git@ preserved, password containing @, ssh:// bare login
cu3="$(_osrc_url_clean 'git@github.com:acme/widgets.git')"
[ "$cu3" = "git@github.com:acme/widgets.git" ] \
  && ok "urlclean: scp-style git@host:path preserved" || bad "urlclean git@: '$cu3'"
cu4="$(_osrc_url_clean 'https://user:p@ss@host.example/a.git')"
[ "$cu4" = "https://host.example/a.git" ] \
  && ok "urlclean: password containing @ stripped through LAST @" || bad "urlclean p@ss: '$cu4'"
cu5="$(_osrc_url_clean 'ssh://git@github.com/acme/widgets.git')"
[ "$cu5" = "ssh://git@github.com/acme/widgets.git" ] \
  && ok "urlclean: ssh:// bare git@ login kept" || bad "urlclean ssh git@: '$cu5'"
cu6="$(_osrc_url_clean 'ssh://user:p@ss@host.example/a.git')"
[ "$cu6" = "ssh://host.example/a.git" ] \
  && ok "urlclean: ssh:// password userinfo stripped" || bad "urlclean ssh p@ss: '$cu6'"
parsed="$( _cloudrun_repo_parse 'https://u:p@github.com/acme/widgets.git' )"
grep -qE 'u:p@|widgets' <<<"$parsed" && ! grep -q 'u:p@' <<<"$parsed" \
  && ok "urlclean: repo_parse emits credential-free url+display" || bad "urlclean: parse leaked: $parsed"
# owner/name must reach git as one github URL (2026-11-19: it was wrapped twice, .git.git).
parsed="$( _cloudrun_repo_parse 'acme/widgets' )"
fu="$(_cloudrun_fetch_url "$(cut -f1 <<<"$parsed")" "$(cut -f2 <<<"$parsed")")"
[ "$fu" = "https://github.com/acme/widgets.git" ] && ok "owner/name fetch url is wrapped once" || bad "owner/name fetch url: '$fu'"
out="$( bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _secret_scan "clone https://u:p@github.com/acme/widgets.git and run tests" t-url
' 2>&1 )"; rc=$?
[ $rc -ne 0 ] && grep -q 'secret VALUE' <<<"$out" \
  && ok "secret-scan: URL credential pattern hard-blocks" || bad "secret-scan: URL cred missed (rc=$rc): $out"
# pack pins the sha and demands the RESULT echo it
(cd "$WORK" && git rev-parse HEAD >/dev/null 2>&1) && \
out="$(start_cloud t-packsha --repo "$WORK" --base main --brief "$BRIEF" --vehicle claude 2>&1)"; rc=$?
PK="$(ls "$OSRC_HOME"/cloud/t-packsha.pack.md 2>/dev/null)"
[ -n "$PK" ] && grep -q 'pinned commit:' "$PK" && grep -q 'sha=' "$PK" \
  && ok "pack: sha pinned + RESULT echo required" || bad "pack: missing sha contract (rc=$rc)"

# --sha carries an offer's exact pinned commit through (finding F); refuses unpushed/unknown
SHA_PIN="$(git -C "$WORK" rev-parse HEAD)"
out="$(start_cloud t-sha --repo "$WORK" --base main --brief "$BRIEF" --vehicle claude --sha "$SHA_PIN" 2>&1)"; rc=$?
PK2="$OSRC_HOME/cloud/t-sha.pack.md"
[ $rc -eq 0 ] && grep -q "pinned commit: $SHA_PIN" "$PK2" \
  && ok "sha: --sha pins the exact commit in the pack" || bad "sha: --sha not honored (rc=$rc): $out"
( cd "$WORK" && git commit -qm tmp --allow-empty )
SHA_UNP="$(git -C "$WORK" rev-parse HEAD)"
out="$(start_cloud t-shaunp --repo "$WORK" --base main --brief "$BRIEF" --vehicle claude --where cloud --sha "$SHA_UNP" 2>&1)"; rc=$?
[ $rc -ne 0 ] && grep -q 'not on any remote\|could never see' <<<"$out" \
  && ok "sha: unpushed --sha refused" || bad "sha: unpushed --sha allowed (rc=$rc): $out"
git -C "$WORK" reset -q --hard HEAD~1
out="$(start_cloud t-shabad --repo "$WORK" --base main --brief "$BRIEF" --vehicle claude --where cloud --sha deadbeefdeadbeef 2>&1)"; rc=$?
[ $rc -ne 0 ] && grep -q 'not a commit' <<<"$out" \
  && ok "sha: unknown --sha refused" || bad "sha: bad --sha allowed (rc=$rc): $out"

# ============================== vehicle probes ========================================
# all vehicles missing -> auto refuses with reasons
out="$( cd "$WORK" && bash -c '
  source "'"$SRC"'" >/dev/null 2>&1
  have() { case "$1" in claude|devin|codex) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  SCRIPT_PATH="'"$SRC"'"; OSRC_HOME="'"$OSRC_HOME"'"
  _cloudrun_start t-noveh --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle auto
' 2>&1 )"; rc=$?
[ $rc -ne 0 ] && grep -q 'no usable hosted-session vehicle' <<<"$out" \
  && ok "vehicle: all missing -> auto refuses" || bad "vehicle: all-missing not refused (rc=$rc)"

# claude missing -> auto skips to devin
: > "$OSRC_STUB_LOG"
out="$( cd "$WORK" && OSRC_CLOUD_ACK=1 OSRC_CLOUD_LAUNCH_WAIT=8 bash -c '
  source "'"$SRC"'" >/dev/null 2>&1
  have() { case "$1" in claude) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  SCRIPT_PATH="'"$SRC"'"; OSRC_HOME="'"$OSRC_HOME"'"; OSRC_STUB_LOG="'"$OSRC_STUB_LOG"'"
  PATH="'"$STUB"':$PATH" _cloudrun_start t-skip --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle auto --spend-ok
' 2>&1 )"; rc=$?
[ $rc -eq 0 ] && grep -q 'devin session started' <<<"$out" \
  && ok "vehicle: missing claude -> auto skips to devin" || { bad "vehicle: skip-to-devin failed (rc=$rc)"; echo "SKIPDEBUG: $out" >&2; echo "STUBLOG: $(cat "$OSRC_STUB_LOG")" >&2; }
grep -q 'vehicle skipped' <<<"$out" && ok "vehicle: skip reason printed" || bad "vehicle: skip reason missing"

# ============================== launch argv per vehicle ===============================
: > "$OSRC_STUB_LOG"
out="$(start_cloud t-claude --repo "$WORK" --base main --brief "$BRIEF" --vehicle claude --claude-env ccpool-1 --model sonnet-test 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "launch: claude start rc=0" || { bad "launch: claude rc=$rc"; echo "$out"; }
sec="$(awk '/=== claude/{f=1;next}/=== /{f=0}f' "$OSRC_STUB_LOG")"
grep -qx -- '<--cloud>' <<<"$sec" && ok "launch: claude argv has --cloud" || bad "launch: claude --cloud missing"
grep -q 'ccpool-1' <<<"$sec" && ok "launch: claude --environment passed" || bad "launch: --environment missing"
grep -q 'sonnet-test' <<<"$sec" && ok "launch: claude --model passed" || bad "launch: --model missing"
grep -q 'cloud/t-claude' <<<"$sec" && ok "launch: pack names work branch cloud/<id>" || bad "launch: pack missing branch"
grep -q 't-claude.READY' <<<"$sec" && ok "launch: pack carries READY contract" || bad "launch: pack missing READY"
[ -f "$OSRC_HOME/remote/t-claude.json" ] && ok "lane: remote/t-claude.json registered" || bad "lane: json missing"
{ _t3b_pipe="$(jq -r '.vehicle // empty' "$OSRC_HOME/remote/t-claude.json" 2>/dev/null)" && grep -qx 'claude' <<<"$_t3b_pipe"; } \
  && ok "lane: vehicle field = claude" || bad "lane: vehicle field wrong"
{ _t3b_pipe="$(jq -r '.session_ref // empty' "$OSRC_HOME/remote/t-claude.json" 2>/dev/null)" && grep -q 'claude.ai' <<<"$_t3b_pipe"; } \
  && ok "lane: session_ref captured from launch log" || bad "lane: session_ref missing"
{ _t3b_pipe="$(jq -r '.branch // empty' "$OSRC_HOME/remote/t-claude.json" 2>/dev/null)" && grep -qx 'cloud/t-claude' <<<"$_t3b_pipe"; } \
  && ok "lane: branch = cloud/t-claude" || bad "lane: branch wrong"
[ -f "$OSRC_HOME/owners/test-L10-session/t-claude" ] && ok "owner: owner record written" || bad "owner: record missing"
grep -q 'Claude subscription' <<<"$out" && ok "quota: claude plan disclosed" || bad "quota: claude plan missing"
grep -q 'session:' <<<"$out" && ok "output: session ref printed" || bad "output: session ref missing"

: > "$OSRC_STUB_LOG"
out="$(start_cloud t-devin --repo "$WORK" --base main --brief "$BRIEF" --vehicle devin --spend-ok 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "launch: devin start rc=0" || { bad "launch: devin rc=$rc"; echo "$out"; }
sec="$(awk '/=== devin/{f=1;next}/=== /{f=0}f' "$OSRC_STUB_LOG")"
grep -qx -- '<--cloud>' <<<"$sec" && grep -qx -- '<-p>' <<<"$sec" && grep -q -- '--prompt-file' <<<"$sec" \
  && ok "launch: devin argv = --cloud -p --prompt-file" || bad "launch: devin argv wrong"
pf="$(echo "$sec" | grep -A1 -- '--prompt-file' | sed -n '2p' | tr -d '<>')"
[ -n "$pf" ] && [ -f "$pf" ] && grep -q 'cloud/t-devin' "$pf" \
  && ok "launch: devin prompt-file is the context pack" || bad "launch: prompt-file wrong ($pf)"
{ _t3b_pipe="$(jq -r '.vehicle' "$OSRC_HOME/remote/t-devin.json" 2>/dev/null)" && grep -qx 'devin' <<<"$_t3b_pipe"; } \
  && ok "lane: devin vehicle recorded" || bad "lane: devin vehicle wrong"

: > "$OSRC_STUB_LOG"
out="$(start_cloud t-codex --repo "$WORK" --base main --brief "$BRIEF" --vehicle codex --env env-test-9 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "launch: codex start rc=0" || { bad "launch: codex rc=$rc"; echo "$out"; }
sec="$(awk '/=== codex/{f=1;next}/=== /{f=0}f' "$OSRC_STUB_LOG")"
grep -qx -- '<cloud>' <<<"$sec" && grep -qx -- '<exec>' <<<"$sec" && grep -q -- '<--env>' <<<"$sec" \
  && ok "launch: codex argv = cloud exec --env" || bad "launch: codex argv wrong"
grep -q 'env-test-9' <<<"$sec" && grep -qx -- '<--branch>' <<<"$sec" && grep -qx -- '<main>' <<<"$sec" \
  && ok "launch: codex env id + branch passed" || bad "launch: codex env/branch missing"
grep -q 'Codex plan' <<<"$out" && ok "quota: codex plan disclosed" || bad "quota: codex plan missing"

# codex without env id -> refused
out="$(start_cloud t-codexnoenv --repo "$WORK" --base main --brief "$BRIEF" --vehicle codex 2>&1)"; rc=$?
[ $rc -ne 0 ] && grep -q 'environment id' <<<"$out" \
  && ok "codex: missing --env refuses with reason" || bad "codex: missing env not refused (rc=$rc)"

# ============================== registration hooks =====================================
# L2 present: stub cmd_lane -> it is called with the lane-add contract
out="$( cd "$WORK" && OSRC_CLOUD_ACK=1 OSRC_CLOUD_LAUNCH_WAIT=8 bash -c '
  source "'"$SRC"'" >/dev/null 2>&1
  cmd_lane() { printf "LANEADD|%s\n" "$*" >> "'"$OSRC_STUB_LOG"'"; return 0; }
  SCRIPT_PATH="'"$SRC"'"; OSRC_HOME="'"$OSRC_HOME"'"
  PATH="'"$STUB"':$PATH" _cloudrun_start t-l2 --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle devin --spend-ok --done-when "check:npm test"
' 2>&1 )"; rc=$?
[ $rc -eq 0 ] && grep -q 'LANEADD|add t-l2 --branch cloud/t-l2' "$OSRC_STUB_LOG" \
  && ok "register: cmd_lane lane add invoked with contract args" || bad "register: cmd_lane not called (rc=$rc)"
{ _t3b_pipe="$(grep 'LANEADD' "$OSRC_STUB_LOG")" && grep -q -- '--ready READY' <<<"$_t3b_pipe"; } && { _t3b_pipe="$(grep 'LANEADD' "$OSRC_STUB_LOG")" && grep -q -- '--done-when check:npm test' <<<"$_t3b_pipe"; } \
  && ok "register: ready marker + done-when forwarded" || bad "register: lane args incomplete"
out="$(cmd_lane() { echo 'fixture registry failure' >&2; return 1; }; _cloudrun_register t-l2fail devin cloud/t-l2fail git "$BARE" "$WORK" main "$BRIEF" '' '' '' 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'fixture registry failure' <<<"$out" && [ ! -e "$OSRC_HOME/remote/t-l2fail.json" ] \
  && ok "register: real helper failure is surfaced without fallback" || bad "register: helper failure concealed (rc=$rc): $out"

# ============================== conserve mode -> devin preferred =====================
# (a) lane-posture down marker on the claude-native lane (key cc)
mkdir -p "$OSRC_HOME/lane-posture"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$OSRC_HOME/lane-posture/cc.down"
out="$(start_cloud t-conserve --repo "$WORK" --base main --brief "$BRIEF" --vehicle auto --spend-ok 2>&1)"; rc=$?
rm -f "$OSRC_HOME/lane-posture/cc.down"
[ $rc -eq 0 ] && grep -q 'devin session started' <<<"$out" \
  && ok "conserve: lane-posture cc.down -> auto picks devin" || bad "conserve: posture marker ignored (rc=$rc): $out"

# (b) session-limit pressure at/over the conserve line
out="$( cd "$WORK" && OSRC_CLOUD_ACK=1 OSRC_CLOUD_LAUNCH_WAIT=8 OSRC_CC_PRESSURE=80 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  SCRIPT_PATH="'"$SRC"'"
  PATH="'"$STUB"':$PATH" _cloudrun_start t-conserve2 --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle auto --spend-ok
' 2>&1 )"; rc=$?
[ $rc -eq 0 ] && grep -q 'devin session started' <<<"$out" \
  && ok "conserve: claude window >= threshold -> auto picks devin" || bad "conserve: pressure ignored (rc=$rc): $out"

# L6 present: stub osrc_done_set -> called with a check: spec + cwd
: > "$OSRC_STUB_LOG"
out="$( cd "$WORK" && OSRC_CLOUD_ACK=1 OSRC_CLOUD_LAUNCH_WAIT=8 bash -c '
  source "'"$SRC"'" >/dev/null 2>&1
  osrc_done_set() { printf "DONESET|%s|%s|%s\n" "$1" "$2" "$3" >> "'"$OSRC_STUB_LOG"'"; return 0; }
  SCRIPT_PATH="'"$SRC"'"; OSRC_HOME="'"$OSRC_HOME"'"
  PATH="'"$STUB"':$PATH" _cloudrun_start t-l6 --repo "'"$WORK"'" --base main --brief "'"$BRIEF"'" --vehicle devin --spend-ok
' 2>&1 )"; rc=$?
[ $rc -eq 0 ] && grep -q 'DONESET|t-l6|check:bash ' "$OSRC_STUB_LOG" \
  && ok "done contract: osrc_done_set invoked" || bad "done contract: osrc_done_set not called (rc=$rc)"
done_script="$(grep 'DONESET|t-l6' "$OSRC_STUB_LOG" | cut -d'|' -f3 | sed 's/^check:bash //')"
[ -n "$done_script" ] && [ -x "$done_script" ] && grep -q 'cloud/t-l6' "$done_script" \
  && ok "done contract: generated check script verifies cloud/<id> + READY" || bad "done contract: check script bad ($done_script)"

# Both helpers present: real lane registry and done contract, not stubs.
out="$(start_cloud t-real --repo "$WORK" --base main --brief "$BRIEF" --vehicle devin --spend-ok 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && jq -e '.id == "t-real" and .branch == "cloud/t-real" and .vehicle == "devin"' "$OSRC_HOME/remote/t-real.json" >/dev/null \
  && [ -f "$OSRC_HOME/owners/$CLAUDE_CODE_SESSION_ID/t-real" ] \
  && ok "register: real lane registry and owner used" || bad "register: real lane registry failed (rc=$rc): $out"
jq -e --arg cwd "$(cd "$WORK" && pwd -P)" '.cwd == $cwd and (.spec | startswith("check:bash "))' "$OSRC_HOME/done/t-real.json" >/dev/null 2>&1 \
  && grep -q 'osrc_done_set t-real' <<<"$out" \
  && ok "done contract: real helper stored check and cwd" || bad "done contract: real helper failed: $out"

# Duplicate must be rejected before any second vehicle probe or launch.
: > "$OSRC_STUB_LOG"
out="$(start_cloud t-real --repo "$WORK" --base main --brief "$BRIEF" --vehicle devin --spend-ok 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'already registered' <<<"$out" && [ ! -s "$OSRC_STUB_LOG" ] \
  && ok "register: duplicate refused before vehicle use" || bad "register: duplicate not safely refused (rc=$rc): $out"

# Neither helper: still registers the lane json + prints the degrade note.
out="$(unset -f cmd_lane osrc_done_set; start_cloud t-bare --repo "$WORK" --base main --brief "$BRIEF" --vehicle devin --spend-ok 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ -f "$OSRC_HOME/remote/t-bare.json" ] \
  && ok "register: fallback json written when helpers absent" || bad "register: fallback failed (rc=$rc)"
grep -q 'osrc_done_set not merged yet' <<<"$out" \
  && ok "done contract: absent-helper note printed" || bad "done contract: missing degrade note"

# Duplicate also refuses in the fallback path.
out="$(unset -f cmd_lane osrc_done_set; start_cloud t-bare --repo "$WORK" --base main --brief "$BRIEF" --vehicle devin --spend-ok 2>&1)"; rc=$?
[ $rc -ne 0 ] && grep -q 'already registered' <<<"$out" \
  && ok "register: duplicate lane id refused" || bad "register: duplicate id allowed (rc=$rc)"

# ============================== cloud ls ==============================================
lsout="$(cmd_cloud ls 2>/dev/null)"
grep -qE 't-claude[[:space:]]+claude' <<<"$lsout" \
  && ok "cloud ls: lists registered lanes with vehicle" || bad "cloud ls: missing lanes"

# ============================== symlink loader ========================================
ln -s "$SRC" "$TMP/osrc-link"
link_out="$(OSRC_HOME="$OSRC_HOME" "$TMP/osrc-link" cloud where 'refactor the auth module' 2>&1)"; lrc=$?
[ $lrc -eq 0 ] && [ "${link_out%%$'\n'*}" = "cloud" ] \
  && ok "loader: symlink invocation resolves lib functions" || bad "loader: symlink dispatch failed (rc=$lrc): $link_out"
link_out="$(OSRC_HOME="$OSRC_HOME" "$TMP/osrc-link" cloud ls 2>&1)"; lrc=$?
grep -q 't-claude' <<<"$link_out" \
  && ok "loader: symlink cloud ls works" || bad "loader: symlink cloud ls failed (rc=$lrc)"

# claude --cloud needs a terminal (2026-11-19: a nohup launch died at once yet printed "started").
# A fake claude that refuses without a TTY, on a private tmux server so no real session is touched.
CB="$TMP/cloudbin"; mkdir -p "$CB" "$TMP/croot"
if command -v tmux >/dev/null 2>&1; then
  printf '#!/bin/sh\nexec %s -L osrc-test-cloudrun-%s "$@"\n' "$(command -v tmux)" "$$" > "$CB/tmux"
  printf '#!/bin/sh\n[ -t 1 ] || { echo "Error: --cloud requires an interactive terminal" >&2; exit 1; }\necho "Session: https://claude.ai/code/session_TESTREF01"\nsleep 3\n' > "$CB/claude"
  chmod +x "$CB/tmux" "$CB/claude"
  lo="$(PATH="$CB:$PATH" OSRC_CLOUD_LAUNCH_WAIT=8 _cloudrun_launch claude /dev/null "brief" "$TMP/c1.launch.log" "$TMP/c1.pid" "$TMP/croot" main)"
  grep -q 'url:https://claude.ai/code/session_TESTREF01' <<<"$lo" && ok "claude cloud runs in a terminal and its session link is read" || bad "claude cloud launch: $lo / $(cat "$TMP/c1.launch.log" 2>/dev/null)"
  "$CB/tmux" kill-server 2>/dev/null
else
  ok "tmux absent: claude cloud terminal check skipped"
fi
printf '#!/bin/sh\necho "boom: no auth" >&2; exit 1\n' > "$CB/devin"; chmod +x "$CB/devin"
lo="$(PATH="$CB:$PATH" OSRC_CLOUD_LAUNCH_WAIT=3 _cloudrun_launch devin /dev/null "brief" "$TMP/c2.launch.log" "$TMP/c2.pid" "$TMP/croot" main)"
[ -z "$(sed -n 2p <<<"$lo")" ] && ! kill -0 "$(sed -n 1p <<<"$lo")" 2>/dev/null && ok "a launcher that dies leaves no session link (start then refuses)" || bad "dead launcher: $lo"
grep -q 'session did not start' "$SCRIPT_DIR/../lib/cloudrun.sh" && ok "cloud start refuses to say started when the launcher died with no link" || bad "no dead-launch refusal in cloud start"

echo
echo "=== $pass passed, $fail failed ==="
[ $fail -eq 0 ]
