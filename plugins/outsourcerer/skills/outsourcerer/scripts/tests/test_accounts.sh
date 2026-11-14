#!/bin/bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-$ROOT/tests}/.account-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home" OSRC_HOME="$TEST_ROOT/state"
mkdir -p "$OSRC_HOME/bin" "$OSRC_HOME/a/token-optimizer" "$OSRC_HOME/b/token-optimizer" "$OSRC_HOME/unknown"
for cli in codex devin droid cursor-agent agent agy gemini cline pi hermes warp curl gh; do
  printf '#!/bin/bash\nexit 99\n' > "$OSRC_HOME/bin/$cli"
  chmod +x "$OSRC_HOME/bin/$cli"
done
mkdir -p "$HOME/.claude/skills" "$HOME/.claude/agents" "$HOME/.claude/projects" "$HOME/.claude/commands" "$HOME/.claude/hooks" "$HOME/.claude/plugins" "$HOME/.claude/references" "$HOME/.claude/statsig" "$HOME/.claude/session-env"
for private in backups sessions daemon jobs tasks teams file-history logs debug telemetry usage-data plans local downloads token-optimizer; do mkdir -p "$HOME/.claude/$private"; done
printf 'identity backup\n' > "$HOME/.claude/.claude.json.backup"
printf 'live state\n' > "$HOME/.claude/loop.md"
printf '{}' > "$HOME/.claude/settings.json"
mkfifo "$HOME/.claude/.credentials.json"
mkfifo "$OSRC_HOME/a/.credentials.json" "$OSRC_HOME/b/.credentials.json"
printf 'private\n' > "$HOME/.claude/.claude.json"
printf 'private\n' > "$HOME/.claude/account-cache.json"
printf 'instructions\n' > "$HOME/.claude/CLAUDE.md"
cat > "$OSRC_HOME/bin/claude" <<'EOF'
#!/bin/bash
if [ "${1:-}" != auth ]; then
  printf '%s|%s\n' "${CLAUDE_CONFIG_DIR-unset}" "${OSRC_ACCOUNT-unset}" >> "$OSRC_HOME/launched"
  printf '%s\n' '{"result":"ok","modelUsage":{}}'
  exit 0
fi
case "$CLAUDE_CONFIG_DIR" in
  */a) printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}' ;;
  */other) printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}' ;;
  */b) printf '%s\n' '{"loggedIn":true,"authMethod":"console","apiProvider":"firstParty","subscriptionType":"max"}' ;;
  */thirdparty) printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"bedrock","subscriptionType":"max"}' ;;
  */unverified) printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}' ;;
  */keysource) printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max","apiKeySource":"helper"}' ;;
  */failed) printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}'; exit 1 ;;
  */ambient) printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}' ;;
  ''|*/.claude) printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}' ;;
  *) printf '%s\n' '{}' ;;
esac
EOF
chmod +x "$OSRC_HOME/bin/claude"
cat > "$OSRC_HOME/bin/hats" <<'EOF'
#!/bin/bash
[ "$#" = 2 ] && [ "$1" = ls ] && [ "$2" = --paths ] || exit 91
[ "${OSRC_TEST_NO_HATS:-0}" != 1 ] || exit 0
printf 'PROFILE  DESKTOP DIR  CONFIG DIR\nhat      %s/desktop  %s/b\n' "$OSRC_HOME" "$OSRC_HOME"
EOF
chmod +x "$OSRC_HOME/bin/hats"
PATH="$OSRC_HOME/bin:$PATH"; export PATH
have() { command -v "$1" >/dev/null 2>&1; }
_timeout() { shift; "$@"; }
. "$ROOT/lib/limits.sh"
. "$ROOT/lib/spend.sh"
_lane_by_disp() { [ "$1" = cc ] && printf cc; }
_extract_kv_value() { return 1; }
_osrc_cap_valid() { case "$1" in weekly\<\=*|5h\<\=*) return 0 ;; *) return 1 ;; esac; }
_osrc_cap_window() { case "$2" in weekly) echo claude7d ;; 5h) echo claude5h ;; *) return 1 ;; esac; }
_osrc_cap_specs_for() { printf '%s\n' "${TEST_CAP:-}"; }
. "$ROOT/lib/accounts.sh"
. "$ROOT/lib/leanlaunch.sh"
MODEL_EXPLICIT=0; EFFORT=''; OSRC_ACCOUNT_DIR="$OSRC_HOME/a"
_cc_effort_flag() { :; }
_session_launch_cc
case " ${SESSION_LAUNCH[*]} " in *" CLAUDE_CONFIG_DIR=$OSRC_HOME/a "*) ;; *) exit 1 ;; esac
unset OSRC_ACCOUNT_DIR
now=$(date +%s)
printf '{"timestamp":%s000,"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":20}}\n' "$now" > "$OSRC_HOME/a/token-optimizer/rate-limits.json"
printf '{"timestamp":%s000,"five_hour":{"used_percentage":30},"seven_day":{"used_percentage":5}}\n' "$now" > "$OSRC_HOME/b/token-optimizer/rate-limits.json"
[ "$(_osrc_account_billing "$OSRC_HOME/a")" = subscription ]
[ "$(_osrc_account_billing "$OSRC_HOME/b")" = metered ]
[ "$(_osrc_account_billing "$OSRC_HOME/thirdparty")" = metered ]
[ "$(_osrc_account_billing "$OSRC_HOME/unverified")" = unknown ]
[ "$(_osrc_account_billing "$OSRC_HOME/keysource")" = metered ]
[ "$(_osrc_account_billing "$OSRC_HOME/failed")" = unknown ]
[ "$(_osrc_account_billing "$OSRC_HOME/unknown")" = unknown ]
printf '{"apiKeyHelper":"example"}\n' > "$OSRC_HOME/a/settings.json"
[ "$(_osrc_account_billing "$OSRC_HOME/a")" = metered ]
rm "$OSRC_HOME/a/settings.json"
CLAUDE_CODE_USE_FOUNDRY=true
export CLAUDE_CODE_USE_FOUNDRY
[ "$(_osrc_account_billing "$OSRC_HOME/a")" = metered ]
unset CLAUDE_CODE_USE_FOUNDRY
accounts=$(printf 'a\t%s/a\nb\t%s/b\nunknown\t%s/unknown\n' "$OSRC_HOME" "$OSRC_HOME" "$OSRC_HOME")
OSRC_SPEND_OK=1
[ "$(printf '%s\n' "$accounts" | _osrc_account_choose)" = a ]
printf 'PASS: spend consent does not outrank a plan\n'
TEST_CAP='5h<=25'; export TEST_CAP
[ "$(printf '%s\n' "$accounts" | _osrc_account_choose)" = a ]
TEST_CAP='weekly<=10'; export TEST_CAP
[ "$(printf '%s\n' "$accounts" | _osrc_account_choose)" = b ]
TEST_CAP='weekly<=5'; export TEST_CAP
if printf '%s\n' "$accounts" | _osrc_account_choose; then exit 1; fi
TEST_CAP=''; export TEST_CAP
printf '{"timestamp":%s000,"seven_day":{"used_percentage":1}}\n' "$((now - 601))" > "$OSRC_HOME/b/token-optimizer/rate-limits.json"
[ "$(printf '%s\n' "$accounts" | _osrc_account_choose)" = a ]
printf '{"timestamp":%s000,"five_hour":{"used_percentage":1}}\n' "$now" > "$OSRC_HOME/b/token-optimizer/rate-limits.json"
[ "$(printf '%s\n' "$accounts" | _osrc_account_choose)" = a ]
printf '{"timestamp":%s000,"seven_day":{"used_percentage":1}}\n' "$now" > "$OSRC_HOME/b/token-optimizer/rate-limits.json"
TEST_CAP='5h<=25'; export TEST_CAP
[ "$(printf '%s\n' "$accounts" | _osrc_account_choose)" = a ]
TEST_CAP=''; export TEST_CAP
unset OSRC_SPEND_OK
CLI="$ROOT/outsourcerer.sh"
(cd "$HOME" && OSRC_TEST_NO_HATS=1 OSRC_NO_AUTODETACH=1 /bin/bash "$CLI" run -m fable --cloud-ack --foreground hello >"$OSRC_HOME/default-run" 2>&1)
[ "$(tail -1 "$OSRC_HOME/launched")" = 'unset|unset' ]
printf 'PASS: default launches without usage or config override\n'
(cd "$HOME" && CLAUDE_CONFIG_DIR="$OSRC_HOME/ambient" OSRC_NO_AUTODETACH=1 /bin/bash "$CLI" run -m fable --cloud-ack --foreground hello >"$OSRC_HOME/ambient-run" 2>&1)
[ "$(tail -1 "$OSRC_HOME/launched")" = "$OSRC_HOME/ambient|unset" ]
printf 'PASS: default preserves caller config\n'
if /bin/bash "$CLI" --osrc-preflight-internal run -m fable --cap '5h<=80' --foreground hello >"$OSRC_HOME/unknown-cap" 2>&1; then exit 1; fi
printf 'PASS: unknown usage cannot satisfy a cap\n'
rm "$OSRC_HOME/launched"
printf '{"timestamp":%s000,"five_hour":{"used_percentage":15},"seven_day":{"used_percentage":25}}\n' "$now" > "$OSRC_HOME/rate-limits.json"
[ "$(_osrc_account_usage "$HOME/.claude")" = '15|25' ]
[ "$(OSRC_CC_PRESSURE=42 _osrc_account_usage "$HOME/.claude")" = '42|' ]
rm "$OSRC_HOME/rate-limits.json"
printf 'PASS: default usage includes the tap file\n'
( _OSRC_LIMITS_SNAP='claude5h=99 codexwk=97'; _OSRC_LIMITS_SNAP_TS="$(date +%s)"; OSRC_ACCOUNT_DIR="$OSRC_HOME/a"; snapshot="$(_osrc_limits_snapshot)"; case "$snapshot" in *codexwk=97*claude5h=10*) ;; *) exit 1 ;; esac )
printf 'PASS: account snapshot retains other lanes\n'
printf '{"apiKeyHelper":"example"}\n' > "$HOME/.claude/settings.json"
[ "$(/bin/bash "$CLI" lane billing cc)" = metered ]
printf '{}\n' > "$HOME/.claude/settings.json"
/bin/bash "$CLI" accounts add work "$OSRC_HOME/a" >/dev/null
[ ! -e "$OSRC_HOME/launched" ]
printf '{"timestamp":%s000,"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":100}}\n' "$now" > "$OSRC_HOME/rate-limits.json"
mv "$OSRC_HOME/a/token-optimizer/rate-limits.json" "$OSRC_HOME/a-usage-saved"
(cd "$HOME" && OSRC_NO_AUTODETACH=1 /bin/bash "$CLI" run -m fable --cloud-ack --foreground hello >"$OSRC_HOME/spent-unknown" 2>&1)
if [ "$(tail -1 "$OSRC_HOME/launched")" != "$OSRC_HOME/a|unset" ]; then echo 'FAIL: spent weekly account beat unknown account'; exit 1; fi
printf 'PASS: spent weekly account loses to unknown account\n'
printf '{"timestamp":%s000,"five_hour":{"used_percentage":100},"seven_day":{"used_percentage":20}}\n' "$now" > "$OSRC_HOME/rate-limits.json"
printf '{"timestamp":%s000,"five_hour":{"used_percentage":5},"seven_day":{"used_percentage":60}}\n' "$now" > "$OSRC_HOME/a/token-optimizer/rate-limits.json"
(cd "$HOME" && OSRC_NO_AUTODETACH=1 /bin/bash "$CLI" run -m fable --cloud-ack --foreground hello >"$OSRC_HOME/spent-5h" 2>&1)
if [ "$(tail -1 "$OSRC_HOME/launched")" != "$OSRC_HOME/a|unset" ]; then echo 'FAIL: spent 5h account beat available account'; exit 1; fi
printf 'PASS: spent 5h account loses to available account\n'
mv "$OSRC_HOME/a-usage-saved" "$OSRC_HOME/a/token-optimizer/rate-limits.json"
rm "$OSRC_HOME/rate-limits.json" "$OSRC_HOME/launched"
if /bin/bash "$CLI" accounts add default "$OSRC_HOME/a" >/dev/null 2>&1; then exit 1; fi
printf 'default\t%s\n' "$OSRC_HOME/a" >> "$OSRC_HOME/claude-accounts"
if /bin/bash "$CLI" accounts rm default >/dev/null 2>&1; then exit 1; fi
[ -p "$HOME/.claude/.credentials.json" ]
[ "$(readlink "$OSRC_HOME/a/settings.json")" = "$HOME/.claude/settings.json" ]
[ "$(readlink "$OSRC_HOME/a/skills")" = "$HOME/.claude/skills" ]
[ "$(readlink "$OSRC_HOME/a/projects")" = "$HOME/.claude/projects" ]
for shared in agents commands hooks plugins references; do
  [ "$(readlink "$OSRC_HOME/a/$shared")" = "$HOME/.claude/$shared" ]
done
if [ ! -p "$OSRC_HOME/a/.credentials.json" ] || [ -L "$OSRC_HOME/a/.credentials.json" ]; then echo 'FAIL: account credential canary changed'; exit 1; fi
[ ! -e "$OSRC_HOME/a/.claude.json" ]
[ ! -e "$OSRC_HOME/a/statsig" ]
[ ! -e "$OSRC_HOME/a/account-cache.json" ]
for private in .claude.json.backup loop.md backups sessions daemon jobs tasks teams file-history logs debug telemetry usage-data plans local downloads token-optimizer; do
  [ "$private" = token-optimizer ] && continue
  if [ -e "$OSRC_HOME/a/$private" ] || [ -L "$OSRC_HOME/a/$private" ]; then echo "FAIL: private path linked: $private"; exit 1; fi
done
if [ ! -d "$OSRC_HOME/a/token-optimizer" ] || [ -L "$OSRC_HOME/a/token-optimizer" ]; then echo 'FAIL: token optimizer is not private'; exit 1; fi
printf 'PASS: only shared configuration is linked\n'
if /bin/bash "$CLI" accounts add inner "$HOME/.claude/inner" >"$OSRC_HOME/inner" 2>&1; then exit 1; fi
[ ! -e "$HOME/.claude/inner" ]
printf 'PASS: default account descendants are rejected\n'
cat > "$OSRC_HOME/bin/mv" <<'EOF'
#!/bin/bash
for last in "$@"; do :; done
[ "$last" != "$OSRC_HOME/claude-accounts" ] || exit 1
exec /bin/mv "$@"
EOF
chmod +x "$OSRC_HOME/bin/mv"
if /bin/bash "$CLI" accounts add retry >"$OSRC_HOME/retry-error" 2>&1; then exit 1; fi
[ ! -e "$OSRC_HOME/claude-account-links/retry" ]
[ ! -L "$HOME/.claude-accounts/retry/CLAUDE.md" ]
rm "$OSRC_HOME/bin/mv"
/bin/bash "$CLI" accounts add retry >/dev/null
/bin/bash "$CLI" accounts rm retry >/dev/null
printf 'PASS: failed registration rolls back links for retry\n'
# The credential canary is a FIFO with no writer: opening it to read would hang
# this sealed, alarm-bounded test, even when filesystem access times are disabled.
[ -p "$HOME/.claude/.credentials.json" ]
/bin/bash "$CLI" accounts check work >/dev/null
rm "$OSRC_HOME/a/skills"
mkdir "$OSRC_HOME/a/skills"
if /bin/bash "$CLI" accounts check work > "$OSRC_HOME/drift" 2>&1; then exit 1; fi
grep -q 'drift: skills' "$OSRC_HOME/drift"
listing=$(/bin/bash "$CLI" accounts)
[[ "$listing" == *work* && "$listing" == *hat* && "$listing" == *default* ]]
[ "$(/bin/bash "$CLI" lane summary --json | jq '[.[] | select(.lane == "cc")] | length')" = 3 ]
printf '{"timestamp":%s000,"five_hour":{"used_percentage":30},"seven_day":{"used_percentage":5}}\n' "$now" > "$OSRC_HOME/b/token-optimizer/rate-limits.json"
/bin/bash "$CLI" --osrc-preflight-internal run -m fable --foreground hello >"$OSRC_HOME/auto" 2>&1
printf 'PASS: auto placement prefers a plan over Console\n'
(cd "$HOME" && OSRC_NO_AUTODETACH=1 /bin/bash "$CLI" run -m fable --spend-ok --cloud-ack --foreground hello >"$OSRC_HOME/approved-auto" 2>&1)
if [ "$(tail -1 "$OSRC_HOME/launched")" != "$OSRC_HOME/a|unset" ]; then echo 'FAIL: spend consent beat available plan'; exit 1; fi
printf 'PASS: spend consent still prefers an available plan\n'
/bin/bash "$CLI" --osrc-preflight-internal run -m fable --cap '5h<=25' --foreground hello >"$OSRC_HOME/capped" 2>&1
if /bin/bash "$CLI" --osrc-preflight-internal run -m fable --account hat --foreground hello >"$OSRC_HOME/denied" 2>&1; then exit 1; fi
grep -q 'spend gate' "$OSRC_HOME/denied"
/bin/bash "$CLI" --osrc-preflight-internal run --spend-ok -m fable --account hat --foreground hello >"$OSRC_HOME/approved" 2>&1
/bin/bash "$CLI" --osrc-preflight-internal run -m fable --account work --foreground hello >"$OSRC_HOME/work" 2>&1
printf '{"apiKeyHelper":"example"}\n' > "$HOME/.claude/settings.json"
if /bin/bash "$CLI" --osrc-preflight-internal run -m fable --account work --foreground hello >"$OSRC_HOME/helper" 2>&1; then exit 1; fi
grep -q 'spend gate' "$OSRC_HOME/helper"
printf '{}\n' > "$HOME/.claude/settings.json"
if /bin/bash "$CLI" --osrc-preflight-internal run -m fable --account hat --cap '5h<=25' --foreground hello >"$OSRC_HOME/forcecap" 2>&1; then exit 1; fi
grep -q 'configured cap' "$OSRC_HOME/forcecap"
if /bin/bash "$CLI" --osrc-preflight-internal run -m fable --account missing --foreground hello >"$OSRC_HOME/missing" 2>&1; then exit 1; fi
grep -q 'unknown Claude account' "$OSRC_HOME/missing"
(cd "$HOME" && OSRC_NO_AUTODETACH=1 /bin/bash "$CLI" run -m fable --account hat --spend-ok --cloud-ack --foreground hello >"$OSRC_HOME/run" 2>&1)
[ "$(tail -1 "$OSRC_HOME/launched")" = "$OSRC_HOME/b|unset" ]
[ "${CLAUDE_CONFIG_DIR:-unset}" = unset ]
(cd "$HOME" && OSRC_ACCOUNT=hat OSRC_NO_AUTODETACH=1 /bin/bash "$CLI" run -m fable --cloud-ack --foreground hello >"$OSRC_HOME/no-leak" 2>&1)
[ "$(tail -1 "$OSRC_HOME/launched")" = "$OSRC_HOME/a|unset" ]
printf 'PASS: inherited account does not force or leak selection\n'
/bin/bash "$CLI" accounts add hat >/dev/null
[ "$(readlink "$OSRC_HOME/b/CLAUDE.md")" = "$HOME/.claude/CLAUDE.md" ]
/bin/bash "$CLI" accounts rm hat >/dev/null
[ ! -L "$OSRC_HOME/b/CLAUDE.md" ]
/bin/bash "$CLI" accounts rm work >/dev/null
[ ! -L "$OSRC_HOME/a/settings.json" ]
if [ ! -d "$OSRC_HOME/a/skills" ] || [ -L "$OSRC_HOME/a/skills" ]; then echo 'FAIL: real skills directory was not preserved'; exit 1; fi
[ -d "$OSRC_HOME/a/token-optimizer" ]
listing=$(/bin/bash "$CLI" accounts)
[[ "$listing" != *work* ]]
mkdir -p "$OSRC_HOME/link"
ln -s "$CLI" "$OSRC_HOME/link/osrc"
listing=$(/bin/bash "$OSRC_HOME/link/osrc" accounts)
[[ "$listing" == *hat* ]]
created=$(/bin/bash "$CLI" accounts add second)
[[ "$created" == *'/login yourself'* ]]
[ "$(readlink "$HOME/.claude-accounts/second/CLAUDE.md")" = "$HOME/.claude/CLAUDE.md" ]
[ ! -e "$HOME/.claude-accounts/second/.credentials.json" ]
/bin/bash "$CLI" accounts rm second >/dev/null
[ ! -L "$HOME/.claude-accounts/second/CLAUDE.md" ]
printf 'account helper checks passed\n'
