#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_lane_billing.sh — L7 r10 split from test_limit_gate.sh (file-size rule): the
# per-lane billing proof rows (osrc_lane_billing classes) and the functional spend-gate
# rows (_osrc_spend_gate consent semantics, .spend-ok markers, fallback pickers never
# selecting a metered lane quietly). Same assertions as the ROUND 3 ADD-ON 1 block that
# used to live in test_limit_gate.sh; that file keeps meter/limit-gate, caps, summary.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR%/}/osrc-lanebilling.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home"; export OSRC_SOURCED=1; mkdir -p "$OSRC_HOME"
# r11 F7: never inherit the real HOME — sourcing probes auth dirs and a real login
# would leak subscription verdicts into rows that forgot HOME=. Every row prefixes
# HOME="$HB" anyway; this covers anything that does not.
export HOME="$TMP/fakehome"; mkdir -p "$HOME"
# Source the REAL script (OSRC_SOURCED=1 skips main); loader 2 finds lib/ exactly as in
# test_limit_gate.sh.
# shellcheck disable=SC1090
. "$SRC" >/dev/null 2>&1
type -t osrc_lane_billing >/dev/null || { echo "FAIL: osrc_lane_billing not defined (lib/spend.sh not loaded?)"; exit 1; }
type -t _osrc_spend_gate >/dev/null || { echo "FAIL: _osrc_spend_gate not defined"; exit 1; }
# FH0: fake HOME for the limit-fallback picker rows (moved here with the block).
FH0="$TMP/fh0"; mkdir -p "$FH0"

# ---------------------------------------------------------------------------------------------------
# ROUND 3 — ADD-ON 1: paid-lane spend gate (lib/spend.sh). osrc_lane_billing classes, unknown->metered,
# non-interactive EVENT approval refusal, --spend-ok one-command-only, env cannot imply consent,
# and fallback pickers never selecting a metered lane quietly.
# ---------------------------------------------------------------------------------------------------
type -t osrc_lane_billing >/dev/null || { echo "FAIL: osrc_lane_billing not defined (lib/spend.sh not loaded?)"; exit 1; }
type -t _osrc_spend_gate >/dev/null || { echo "FAIL: _osrc_spend_gate not defined"; exit 1; }
HB="$TMP/hb"; mkdir -p "$HB"

# Billing classes — each in a subshell with a controlled HOME (no ~/.env, no real auth files).
b=$( HOME="$HB" OSRC_SPEND_GATE=0 bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing local' )
[ "$b" = "free" ] && ok "r3 billing: local -> free" || bad "r3 billing: local -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing or' )
[ "$b" = "metered" ] && ok "r3 billing: or (OpenRouter) -> metered" || bad "r3 billing: or -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing tokenrouter; osrc_lane_billing gi' )
case "$b" in metered$'\n'metered) ok "r3 billing: tokenrouter + gi -> metered" ;; *) bad "r3 billing: tr/gi -> '$b'" ;; esac
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing ci; osrc_lane_billing claudex' )
case "$b" in unknown$'\n'unknown) ok "r9 billing: ci unproven + claudex upstream unverifiable -> unknown" ;; *) bad "r9 billing: ci/claudex -> '$b'" ;; esac
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing cursor; osrc_lane_billing grokbot' )
case "$b" in unknown$'\n'unknown) ok "r3 billing: cursor + grokbot unprovable -> unknown" ;; *) bad "r3 billing: cursor/grokbot -> '$b'" ;; esac
# Devin spend-free is PROOF-based: live catalog Free tag, else only SWE-2 High / SWE-2 Flash
# High offline. glm-5.2 (plan-included for quota) is NOT proven Free for spend -> metered.
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = devin ] && return 0; command -v "$1" >/dev/null 2>&1; }; _devin_catalog_free_ids() { return 1; }; osrc_lane_billing dv glm-5.2' )
[ "$b" = "metered" ] && ok "r3 billing: dv glm-5.2 not-proven-Free -> metered" || bad "r3 billing: dv glm-5.2 -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = devin ] && return 0; command -v "$1" >/dev/null 2>&1; }; _devin_catalog_free_ids() { return 1; }; osrc_lane_billing dv swe-2-high; osrc_lane_billing dv swe-2-flash-high' )
case "$b" in subscription$'\n'subscription) ok "r3 billing: dv offline fallback swe-2-high + swe-2-flash-high -> subscription" ;; *) bad "r3 billing: dv offline fallback -> '$b'" ;; esac
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = devin ] && return 0; command -v "$1" >/dev/null 2>&1; }; _devin_catalog_free_ids() { printf "swe-2-max glm-5.2 "; return 0; }; osrc_lane_billing dv glm-5.2; osrc_lane_billing dv swe-2-max' )
case "$b" in subscription$'\n'subscription) ok "r3 billing: dv live catalog Free ids -> subscription" ;; *) bad "r3 billing: dv catalog free -> '$b'" ;; esac
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; _devin_catalog_free_ids() { printf "swe-2-max "; return 0; }; have() { [ "$1" = devin ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing dv swe-2-high' )
[ "$b" = "metered" ] && ok "r3 billing: reachable catalog overrides static fallback (swe-2-high not Free -> metered)" || bad "r3 billing: catalog-vs-static -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { return 1; }; osrc_lane_billing dv swe-2-high' )
[ "$b" = "unknown" ] && ok "r3 billing: dv no CLI -> unknown" || bad "r3 billing: dv no cli -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing nosuchlane' )
[ "$b" = "unknown" ] && ok "r3 billing: unresolvable lane -> unknown" || bad "r3 billing: bogus -> '$b'"

# cc: API key -> metered; proven plan login -> subscription; CLI alone or redirect vars ->
# metered/unknown. Round 3.1: subscription requires PROOF (credentials/keychain/auth-dir),
# and every per-use redirect (token, base URL, BEDROCK/VERTEX, settings key helper) is metered.
b=$( HOME="$HB" ANTHROPIC_API_KEY=x bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing cc' )
[ "$b" = "metered" ] && ok "r3 billing: cc + ANTHROPIC_API_KEY -> metered" || bad "r3 billing: cc+key -> '$b'"
# r9 F1: cc subscription proof is `claude auth status` JSON ONLY — loggedIn==true,
# authMethod=="claude.ai", apiProvider=="firstParty", subscriptionType in
# pro|max|team|enterprise. A credentials file, keychain entry, Console/API-key login,
# missing fields, non-JSON, exit!=0 or no jq are all unknown. claude() is a shell
# function stub (it reaches _timeout's subshell); CLF carries the fixture JSON.
_ccbill() { local fx="$1"; shift; env HOME="$HB" CLF="$fx" "$@" bash -c '. "$1" >/dev/null 2>&1
  have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }
  claude() { printf "%s" "$CLF"; }
  osrc_lane_billing cc' _ "$SRC" 2>/dev/null; }
# r11 F1: the canonical fixture is the REAL shape — `claude auth status` pretty-prints
# (JSON.stringify(_, null, 2)), ~16 indented lines. Values are faked; field set matches
# a real capture. The variant/negative rows below stay one-line, so BOTH shapes are
# covered: indented via PLANJSON, one-line via the inline strings.
PLANJSON='{
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
}'
[ "$(_ccbill "$PLANJSON")" = "subscription" ] && ok "r9 billing: cc plan login max (indented real shape) -> subscription" || bad "r9 billing: cc max-indented -> '$(_ccbill "$PLANJSON")'"
# The Claude desktop app exports ANTHROPIC_BASE_URL=https://api.anthropic.com (the stock
# first-party endpoint) into every session. That is not a redirect: a plan login must stay
# subscription. Any other host is still a redirect and bills per-use.
for u in https://api.anthropic.com https://api.anthropic.com/ HTTPS://API.ANTHROPIC.COM; do
  b="$(_ccbill "$PLANJSON" ANTHROPIC_BASE_URL="$u")"
  [ "$b" = "subscription" ] && ok "billing: cc plan login + first-party base URL $u -> subscription" || bad "billing: cc first-party base URL $u -> '$b'"
done
b="$(_ccbill "$PLANJSON" ANTHROPIC_BASE_URL=https://proxy.example)"
[ "$b" = "metered" ] && ok "billing: cc plan login + foreign base URL -> metered" || bad "billing: cc foreign base URL -> '$b'"
# S5 (#78 review): the stock endpoint is matched exactly after trimming surrounding whitespace
# (the SDK trims) and trailing slashes. Everything else fails toward metered: plain http, a path,
# a port, userinfo, lookalike hosts, and the stock host buried in a foreign URL.
for u in ' https://api.anthropic.com' $'https://api.anthropic.com\n' $'\thttps://api.anthropic.com/ ' 'https://api.anthropic.com///'; do
  b="$(_ccbill "$PLANJSON" ANTHROPIC_BASE_URL="$u")"
  [ "$b" = "subscription" ] && ok "billing: cc stock base URL with whitespace/slashes '$u' -> subscription" || bad "billing: cc stock base URL '$u' -> '$b'"
done
for u in http://api.anthropic.com https://api.anthropic.com/v1 https://api.anthropic.com:8443 \
         https://api.anthropic.com.evil.tld https://evil.tld/api.anthropic.com https://api.anthropic.com@evil.tld \
         api.anthropic.com 'https://api.anthropic .com' https://xapi.anthropic.com; do
  b="$(_ccbill "$PLANJSON" ANTHROPIC_BASE_URL="$u")"
  [ "$b" = "metered" ] && ok "billing: cc non-stock base URL $u -> metered" || bad "billing: cc non-stock base URL $u -> '$b'"
done
b="$(_ccbill "$PLANJSON" ANTHROPIC_BASE_URL=)"
[ "$b" = "subscription" ] && ok "billing: cc empty base URL -> subscription" || bad "billing: cc empty base URL -> '$b'"
for u in / /// ' / '; do
  b="$(_ccbill "$PLANJSON" ANTHROPIC_BASE_URL="$u")"
  [ "$b" = "metered" ] && ok "billing: cc slash-only base URL '$u' -> metered (not empty)" || bad "billing: cc slash-only base URL '$u' -> '$b'"
done
# Same rule for settings.json env (the same class: the stock value written there is not a proxy).
mkdir -p "$HB/.claude"
for sj in '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}' '{"env":{"ANTHROPIC_BASE_URL":"HTTPS://API.ANTHROPIC.COM/ "}}' '{"env":{}}' '{"env":{"ANTHROPIC_BASE_URL":""}}'; do
  printf '%s' "$sj" > "$HB/.claude/settings.json"; b="$(_ccbill "$PLANJSON")"
  [ "$b" = "subscription" ] && ok "billing: cc settings $sj -> subscription" || bad "billing: cc settings $sj -> '$b'"
done
for sj in '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com.evil.tld"}}' '{"env":{"ANTHROPIC_BASE_URL":"http://api.anthropic.com"}}' '{"env":{"ANTHROPIC_BASE_URL":["https://api.anthropic.com"]}}' '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","ANTHROPIC_AUTH_TOKEN":"t"}}'; do
  printf '%s' "$sj" > "$HB/.claude/settings.json"; b="$(_ccbill "$PLANJSON")"
  [ "$b" = "metered" ] && ok "billing: cc settings $sj -> metered" || bad "billing: cc settings $sj -> '$b'"
done
# A settings.json jq cannot parse still counts its proxy/key lines (plain grep fallback).
for sj in '{"env":{"ANTHROPIC_BASE_URL":"https://proxy.example",}}' $'{\n  // proxy\n  "env":{"ANTHROPIC_API_KEY":"sk-x"}}'; do
  printf '%s' "$sj" > "$HB/.claude/settings.json"; b="$(_ccbill "$PLANJSON")"
  [ "$b" = "metered" ] && ok "billing: cc unparsable settings with a redirect -> metered" || bad "billing: cc unparsable settings $sj -> '$b'"
done
rm -f "$HB/.claude/settings.json"
for st in pro team enterprise; do
  j="{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"subscriptionType\":\"$st\"}"
  b="$(_ccbill "$j")"
  [ "$b" = "subscription" ] && ok "r9 billing: cc plan login $st -> subscription" || bad "r9 billing: cc $st -> '$b'"
done
[ "$(_ccbill '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"console"}')" = "unknown" ] \
  && ok "r9 billing: cc non-plan subscriptionType -> unknown" || bad "r9 billing: cc console-type -> subscription?!"
[ "$(_ccbill '{"loggedIn":true,"authMethod":"console","apiProvider":"console","subscriptionType":null}')" = "unknown" ] \
  && ok "r9 billing: cc console login -> unknown" || bad "r9 billing: cc console -> subscription?!"
[ "$(_ccbill '{"loggedIn":true,"authMethod":"apiKey","apiProvider":"firstParty"}')" = "unknown" ] \
  && ok "r9 billing: cc api-key shape -> unknown" || bad "r9 billing: cc apikey -> subscription?!"
[ "$(_ccbill '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":null}')" = "unknown" ] \
  && ok "r9 billing: cc null subscriptionType -> unknown" || bad "r9 billing: cc null-type -> subscription?!"
[ "$(_ccbill '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}')" = "unknown" ] \
  && ok "r9 billing: cc missing subscriptionType -> unknown" || bad "r9 billing: cc missing-type -> subscription?!"
[ "$(_ccbill '{"loggedIn":false,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}')" = "unknown" ] \
  && ok "r9 billing: cc loggedIn false -> unknown" || bad "r9 billing: cc loggedIn-false -> subscription?!"
[ "$(_ccbill 'not json at all')" = "unknown" ] && ok "r9 billing: cc garbage auth status -> unknown" || bad "r9 billing: cc garbage -> subscription?!"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; claude() { return 1; }; osrc_lane_billing cc' )
[ "$b" = "unknown" ] && ok "r9 billing: cc auth status exit 1 -> unknown" || bad "r9 billing: cc exit1 -> '$b'"
b=$( HOME="$HB" PLANJSON="$PLANJSON" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; [ "$1" = jq ] && return 1; command -v "$1" >/dev/null 2>&1; }; claude() { printf "%s" "$PLANJSON"; }; osrc_lane_billing cc' )
[ "$b" = "unknown" ] && ok "r9 billing: cc no jq -> unknown" || bad "r9 billing: cc no-jq -> '$b'"
# File/keychain existence is NOT proof: a real-shaped creds block plus garbage CLI
# output still yields unknown; a keychain entry without a plan yields unknown.
mkdir -p "$HB/.claude"; printf '{"claudeAiOauth":{"subscriptionType":"max","accessToken":"x"}}' > "$HB/.claude/.credentials.json"
[ "$(_ccbill 'garbage')" = "unknown" ] && ok "r9 billing: real-shaped creds file + garbage CLI -> unknown" || bad "r9 billing: creds-file proved subscription?!"
: > "$HB/.claude/.credentials.json"
[ "$(_ccbill '')" = "unknown" ] && ok "r9 billing: empty creds file -> unknown" || bad "r9 billing: empty creds -> subscription?!"
printf 'garbage' > "$HB/.claude/.credentials.json"
[ "$(_ccbill '')" = "unknown" ] && ok "r9 billing: garbage creds file -> unknown" || bad "r9 billing: garbage creds -> subscription?!"
b=$( HOME="$HB" OSRC_PLATFORM=darwin bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; security() { return 0; }; claude() { echo garbage; }; osrc_lane_billing cc' )
[ "$b" = "unknown" ] && ok "r9 billing: keychain entry without plan -> unknown" || bad "r9 billing: keychain -> '$b'"
rm -f "$HB/.claude/.credentials.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; ANTHROPIC_AUTH_TOKEN=t ANTHROPIC_BASE_URL=https://openrouter.ai/api osrc_lane_billing cc' )
[ "$b" = "metered" ] && ok "r3 billing: cc auth-token+base-url redirect -> metered" || bad "r3 billing: cc redirect -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; CLAUDE_CODE_USE_BEDROCK=1 osrc_lane_billing cc; CLAUDE_CODE_USE_VERTEX=1 osrc_lane_billing cc' )
case "$b" in metered$'\n'metered) ok "r3 billing: cc BEDROCK+VERTEX -> metered" ;; *) bad "r3 billing: cc bedrock/vertex -> '$b'" ;; esac
printf '{"apiKeyHelper":"/bin/echo sk-x"}' > "$HB/.claude/settings.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing cc' )
[ "$b" = "metered" ] && ok "r3 billing: cc settings apiKeyHelper -> metered" || bad "r3 billing: cc apikeyhelper -> '$b'"
printf '{"env":{"ANTHROPIC_API_KEY":"sk-x"}}' > "$HB/.claude/settings.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing cc' )
[ "$b" = "metered" ] && ok "r3 billing: cc settings env.ANTHROPIC_API_KEY -> metered" || bad "r3 billing: cc settings envkey -> '$b'"
rm -f "$HB/.claude/settings.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; claude() { :; }; rm -f "$HOME/.claude/.credentials.json"; osrc_lane_billing cc' )
[ "$b" = "unknown" ] && ok "r3 billing: cc CLI but no provable login -> unknown" || bad "r3 billing: cc cli-only -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { return 1; }; osrc_lane_billing cc' )
[ "$b" = "unknown" ] && ok "r3 billing: cc unprovable -> unknown" || bad "r3 billing: cc unknown -> '$b'"
# r10 4.2: a non-zero `claude auth status` exit is NOT proof even when plan-shaped JSON
# was printed — the exit code is captured before jq ever sees the payload.
b=$( HOME="$HB" PLANJSON="$PLANJSON" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }
  claude() { printf "%s" "$PLANJSON"; return 1; }; osrc_lane_billing cc' )
[ "$b" = "unknown" ] && ok "r10 billing: cc plan JSON + exit 1 -> unknown" || bad "r10 billing: cc exit1+json -> '$b'"
# r10 4.3: plan proof tolerates case and plan variants — "Max" and "max_20x" are the
# same plan family; a non-JSON line before the payload does not cost an ask.
[ "$(_ccbill '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"Max"}')" = "subscription" ] \
  && ok "r10 billing: cc subscriptionType Max (case) -> subscription" || bad "r10 billing: cc Max -> subscription?!"
[ "$(_ccbill '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max_20x"}')" = "subscription" ] \
  && ok "r10 billing: cc subscriptionType max_20x (variant) -> subscription" || bad "r10 billing: cc max_20x -> subscription?!"
[ "$(_ccbill 'WARNING: deprecated flag
{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"team"}')" = "subscription" ] \
  && ok "r10 billing: cc leading non-JSON line + plan JSON -> subscription" || bad "r10 billing: cc leading-junk -> subscription?!"
# ...but a JSON object that is NOT the auth payload still wins "first object" and fails safe.
[ "$(_ccbill '{"notice":"hi"}
{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}')" = "unknown" ] \
  && ok "r10 billing: cc first-JSON-object rule fails safe on foreign object" || bad "r10 billing: cc foreign-object -> subscription?!"
# r11 F1 rows: pretty shape alone, one-line shape alone, warning + pretty, foreign first,
# garbage — the exact six shapes the verdict exercised.
[ "$(_ccbill "$PLANJSON")" = "subscription" ] && ok "r11 billing: cc pretty-printed plan JSON -> subscription" || bad "r11 billing: cc pretty -> subscription?!"
[ "$(_ccbill '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}')" = "subscription" ] \
  && ok "r11 billing: cc one-line plan JSON -> subscription" || bad "r11 billing: cc one-line -> subscription?!"
[ "$(_ccbill 'WARNING: deprecated flag
{
  "loggedIn": true,
  "authMethod": "claude.ai",
  "apiProvider": "firstParty",
  "subscriptionType": "max"
}')" = "subscription" ] \
  && ok "r11 billing: cc warning line + pretty JSON -> subscription" || bad "r11 billing: cc warn+pretty -> subscription?!"
# r11 F2a: a key/helper source beside the plan login is NOT subscription — the CLI
# reports it as apiKeySource and the plan check requires it null.
[ "$(_ccbill '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","apiKeySource":"apiKeyHelper","subscriptionType":"max"}')" = "unknown" ] \
  && ok "r11 billing: cc apiKeySource set beside plan login -> unknown" || bad "r11 billing: cc apikeysource -> subscription?!"
# r11 F2b: settings env.* redirects and CLAUDE_CONFIG_DIR all classify metered.
printf '{"env":{"ANTHROPIC_BASE_URL":"https://proxy.example","ANTHROPIC_AUTH_TOKEN":"t"}}' > "$HB/.claude/settings.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing cc' )
[ "$b" = "metered" ] && ok "r11 billing: cc settings env.ANTHROPIC_BASE_URL+AUTH_TOKEN -> metered" || bad "r11 billing: cc settings baseurl -> '$b'"
printf '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}' > "$HB/.claude/settings.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing cc' )
[ "$b" = "metered" ] && ok "r11 billing: cc settings env.CLAUDE_CODE_USE_BEDROCK -> metered" || bad "r11 billing: cc settings bedrock -> '$b'"
printf '{"env":{"CLAUDE_CODE_USE_VERTEX":"true"}}' > "$HB/.claude/settings.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing cc' )
[ "$b" = "metered" ] && ok "r11 billing: cc settings env.CLAUDE_CODE_USE_VERTEX=true -> metered" || bad "r11 billing: cc settings vertex -> '$b'"
rm -f "$HB/.claude/settings.json"
# CLAUDE_CONFIG_DIR is honoured like CODEX_HOME: a helper there bills per-use even
# when ~/.claude/settings.json is clean.
mkdir -p "$HB/ccfg"; printf '{"apiKeyHelper":"/bin/echo sk-x"}' > "$HB/ccfg/settings.json"
b=$( HOME="$HB" CLAUDE_CONFIG_DIR="$HB/ccfg" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing cc' )
[ "$b" = "metered" ] && ok "r11 billing: cc CLAUDE_CONFIG_DIR apiKeyHelper -> metered" || bad "r11 billing: cc configdir -> '$b'"
rm -rf "$HB/ccfg"
# Exported switches accept truthy values, not only literal "1".
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; CLAUDE_CODE_USE_BEDROCK=true osrc_lane_billing cc; CLAUDE_CODE_USE_FOUNDRY=1 osrc_lane_billing cc' )
case "$b" in metered$'\n'metered) ok "r11 billing: cc exported BEDROCK=true + FOUNDRY=1 -> metered" ;; *) bad "r11 billing: cc flag-on -> '$b'" ;; esac
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; claude() { echo garbage; }; CLAUDE_CODE_USE_BEDROCK=0 osrc_lane_billing cc; CLAUDE_CODE_USE_VERTEX=false osrc_lane_billing cc' )
[ "$b" = "unknown"$'\n'"unknown" ] && ok "r11 billing: cc exported BEDROCK=0 + VERTEX=false stay off -> unknown" || bad "r11 billing: cc flag-off -> '$b'"

# cx: ChatGPT auth.json -> subscription; OPENAI_API_KEY -> metered; nothing -> unknown.
mkdir -p "$HB/.codex"; printf '{"tokens":{"access_token":"x"}}' > "$HB/.codex/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in subscription$'\n'subscription) ok "r3 billing: cx + ci ChatGPT login -> subscription" ;; *) bad "r3 billing: cx/ci auth.json -> '$b'" ;; esac
printf '{"OPENAI_API_KEY":"sk-x"}' > "$HB/.codex/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in metered$'\n'metered) ok "r3 billing: cx + ci auth.json API key -> metered" ;; *) bad "r3 billing: cx/ci apikey -> '$b'" ;; esac
rm -rf "$HB/.codex"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { return 1; }; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in unknown$'\n'unknown) ok "r3 billing: cx + ci unprovable -> unknown" ;; *) bad "r3 billing: cx/ci unknown -> '$b'" ;; esac

# r9 class-check: `codex login status` distinguishes plan from per-use — "Logged in using
# ChatGPT" is subscription, "Logged in using an API key" bills per token -> metered,
# anything else -> unknown. (No auth.json present, so the CLI probe is what decides.)
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = codex ] && return 0; command -v "$1" >/dev/null 2>&1; }; codex() { echo "Logged in using ChatGPT"; }; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in subscription$'\n'subscription) ok "r9 billing: cx + ci login status ChatGPT -> subscription" ;; *) bad "r9 billing: cx/ci chatgpt-status -> '$b'" ;; esac
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = codex ] && return 0; command -v "$1" >/dev/null 2>&1; }; codex() { echo "Logged in using an API key - sk-***1234"; }; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in metered$'\n'metered) ok "r9 billing: cx + ci login status API key -> metered" ;; *) bad "r9 billing: cx/ci apikey-status -> '$b'" ;; esac
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = codex ] && return 0; command -v "$1" >/dev/null 2>&1; }; codex() { echo "Not logged in"; }; osrc_lane_billing cx' )
[ "$b" = "unknown" ] && ok "r9 billing: cx login status not-logged-in -> unknown" || bad "r9 billing: cx not-logged-in -> '$b'"

# r9 class-check: auth.json must prove a billing class POSITIVELY — {} / garbage /
# tokenless shapes are evidence of NEITHER (same class as the claude {} fix) -> unknown,
# never guessed subscription. have() claims jq only, so the real jq classification runs
# while codex is absent (no CLI fallback can rescue these rows).
mkdir -p "$HB/.codex"; printf '{}' > "$HB/.codex/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = jq ] && return 0; return 1; }; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in unknown$'\n'unknown) ok "r9 billing: cx/ci empty auth.json -> unknown" ;; *) bad "r9 billing: cx/ci {} auth.json -> '$b'" ;; esac
printf 'not json{{{' > "$HB/.codex/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = jq ] && return 0; return 1; }; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in unknown$'\n'unknown) ok "r9 billing: cx/ci garbage auth.json -> unknown" ;; *) bad "r9 billing: cx/ci garbage auth.json -> '$b'" ;; esac
printf '{"tokens":{}}' > "$HB/.codex/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = jq ] && return 0; return 1; }; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in unknown$'\n'unknown) ok "r9 billing: cx/ci tokenless auth.json -> unknown" ;; *) bad "r9 billing: cx/ci tokenless auth.json -> '$b'" ;; esac
rm -rf "$HB/.codex"

# r10 F1: CODEX_HOME is honoured — auth.json lives at ${CODEX_HOME:-$HOME/.codex}.
# A stale plan token in ~/.codex must NOT rescue an API-key login in CODEX_HOME.
mkdir -p "$HB/.codex" "$HB/codexhome"
printf '{"tokens":{"access_token":"stale-plan"}}' > "$HB/.codex/auth.json"
printf '{"OPENAI_API_KEY":"sk-x"}' > "$HB/codexhome/auth.json"
b=$( HOME="$HB" CODEX_HOME="$HB/codexhome" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = jq ] && return 0; return 1; }; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in metered$'\n'metered) ok "r10 billing: CODEX_HOME api-key auth beats stale ~/.codex plan token -> metered" ;; *) bad "r10 billing: CODEX_HOME -> '$b'" ;; esac
# And the CLI's per-use answer wins over a token file: codex says API key while
# CODEX_HOME's auth.json still carries plan tokens -> metered, not subscription.
printf '{"tokens":{"access_token":"x"}}' > "$HB/codexhome/auth.json"
b=$( HOME="$HB" CODEX_HOME="$HB/codexhome" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  have() { case "$1" in codex|jq) return 0 ;; *) return 1 ;; esac; }
  codex() { echo "Logged in using an API key - sk-***1234"; }; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in metered$'\n'metered) ok "r10 billing: codex CLI api-key answer beats token file -> metered" ;; *) bad "r10 billing: cli-apikey-vs-file -> '$b'" ;; esac
# CODEX_HOME token file alone (no CLI) is still positive plan proof.
b=$( HOME="$HB" CODEX_HOME="$HB/codexhome" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = jq ] && return 0; return 1; }; osrc_lane_billing cx' )
[ "$b" = "subscription" ] && ok "r10 billing: CODEX_HOME token file -> subscription" || bad "r10 billing: codexhome tokens -> '$b'"
rm -rf "$HB/.codex" "$HB/codexhome"

# r9 class-check: dir-auth subscription proof must not pass a BYOK login — api-key
# material inside the lane's auth dir -> metered; a plain auth file still -> subscription.
mkdir -p "$HB/.cursor"; printf '{"auth":"session-token"}' > "$HB/.cursor/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { case "$1" in cursor-agent|agent) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }; osrc_lane_billing cursor' )
[ "$b" = "subscription" ] && ok "r9 billing: cursor auth dir, no key material -> subscription" || bad "r9 billing: cursor plain-auth -> '$b'"
printf '{"apiKey":"cursor-key-abcdef123456"}' > "$HB/.cursor/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { case "$1" in cursor-agent|agent) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }; osrc_lane_billing cursor' )
[ "$b" = "metered" ] && ok "r9 billing: cursor auth dir apiKey -> metered" || bad "r9 billing: cursor dir-key -> '$b'"
rm -rf "$HB/.cursor"

mkdir -p "$HB/.factory"; printf '{"auth":"session"}' > "$HB/.factory/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = droid ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing droid' )
[ "$b" = "subscription" ] && ok "r9 billing: droid auth dir, no key material -> subscription" || bad "r9 billing: droid plain-auth -> '$b'"
printf '{"api_key":"factory-key-abcdef123456"}' > "$HB/.factory/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = droid ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing droid' )
[ "$b" = "metered" ] && ok "r9 billing: droid auth dir api_key -> metered" || bad "r9 billing: droid dir-key -> '$b'"
rm -rf "$HB/.factory"
# r10 F2: BYOK keys hide in config files too — _osrc_dir_key_material scans EVERY
# depth-1 file, so custom_models[].api_key / customModels[].apiKey -> metered.
mkdir -p "$HB/.factory"; printf '{"auth":"session"}' > "$HB/.factory/auth.json"
printf '{"custom_models":[{"name":"x","api_key":"factory-key-abcdef123456"}]}' > "$HB/.factory/config.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = droid ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing droid' )
[ "$b" = "metered" ] && ok "r10 billing: droid config.json custom_models api_key -> metered" || bad "r10 billing: droid config.json -> '$b'"
rm -f "$HB/.factory/config.json"
printf '{"customModels":[{"apiKey":"factory-key-abcdef123456"}]}' > "$HB/.factory/settings.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = droid ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing droid' )
[ "$b" = "metered" ] && ok "r10 billing: droid settings.json customModels apiKey -> metered" || bad "r10 billing: droid settings.json -> '$b'"
rm -rf "$HB/.factory"
# r11 F5: a history/cache/log/tmp artefact is NOT a login — session-history.json
# records past sessions; only auth-ish non-empty files prove _osrc_dir_auth.
mkdir -p "$HB/.factory"; printf '[{"session":"old"}]' > "$HB/.factory/session-history.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = droid ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing droid' )
[ "$b" = "unknown" ] && ok "r11 billing: droid session-history.json only -> unknown" || bad "r11 billing: droid history-file -> '$b'"
printf '' > "$HB/.factory/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = droid ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing droid' )
[ "$b" = "unknown" ] && ok "r11 billing: droid EMPTY auth.json -> unknown" || bad "r11 billing: droid empty-auth -> '$b'"
rm -rf "$HB/.factory"

mkdir -p "$HB/.warp"; printf '{"auth":"session"}' > "$HB/.warp/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = oz ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing warp' )
[ "$b" = "subscription" ] && ok "r9 billing: warp auth dir, no key material -> subscription" || bad "r9 billing: warp plain-auth -> '$b'"
printf '{"api-key":"warp-key-abcdef123456"}' > "$HB/.warp/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = oz ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing warp' )
[ "$b" = "metered" ] && ok "r9 billing: warp auth dir api-key -> metered" || bad "r9 billing: warp dir-key -> '$b'"
rm -rf "$HB/.warp"

# r10 4.1: an EMPTY ~/.antigravity dir is not a login — dir existence alone must not
# classify subscription (same class as the credentials fix). A non-empty login file is.
mkdir -p "$HB/.antigravity"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = agy ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing gm' )
[ "$b" = "unknown" ] && ok "r10 billing: gm empty .antigravity dir + agy -> unknown" || bad "r10 billing: gm empty-dir -> '$b'"
printf '{"auth":"session"}' > "$HB/.antigravity/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = agy ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing gm' )
[ "$b" = "subscription" ] && ok "r10 billing: gm non-empty login file + agy -> subscription" || bad "r10 billing: gm login-file -> '$b'"
rm -rf "$HB/.antigravity"
# r11 F5: junk files do not prove a login — .DS_Store, argv.json (written by an
# editor install before sign-in) and *.log are excluded from the state-file proof.
mkdir -p "$HB/.antigravity"; printf 'junk' > "$HB/.antigravity/.DS_Store"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = agy ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing gm' )
[ "$b" = "unknown" ] && ok "r11 billing: gm .DS_Store only -> unknown" || bad "r11 billing: gm dsstore -> '$b'"
printf '{"argv":[]}' > "$HB/.antigravity/argv.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = agy ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing gm' )
[ "$b" = "unknown" ] && ok "r11 billing: gm argv.json only -> unknown" || bad "r11 billing: gm argvjson -> '$b'"
printf 'log line' > "$HB/.antigravity/run.log"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = agy ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing gm' )
[ "$b" = "unknown" ] && ok "r11 billing: gm *.log only -> unknown" || bad "r11 billing: gm logfile -> '$b'"
rm -rf "$HB/.antigravity"

# r9 class-check FUNCTIONAL: the spend gate itself, non-interactive with no consent.
# Every lane whose billing rule changed must REFUSE on unproven/metered and PROCEED
# only on positive plan/free proof — same call shape route_delegate uses.
# claudex: upstream billing is not externally provable -> unknown -> refuse.
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate claudex gpt-5.6-sol claudex "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills unknown"*) ok "r9 spend: claudex unknown -> non-interactive refuse" ;;
  *) bad "r9 spend: claudex gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
# cx/ci auth.json: unproven shapes -> unknown -> refuse; api-key field -> metered -> refuse;
# OAuth access_token -> subscription -> proceed. Real jq on PATH classifies; the codex
# stub exits 99 so no CLI probe can rescue the unproven rows.
mkdir -p "$HB/.codex"; printf '{}' > "$HB/.codex/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate cx "" cxnative "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills unknown"*) ok "r9 spend: cx empty auth.json -> refuse" ;;
  *) bad "r9 spend: cx {} gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate ci "" cxnative "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills unknown"*) ok "r9 spend: ci empty auth.json -> refuse" ;;
  *) bad "r9 spend: ci {} gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
printf '{"OPENAI_API_KEY":"sk-x"}' > "$HB/.codex/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate cx "" cxnative "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills metered"*) ok "r9 spend: cx api-key auth.json -> refuse" ;;
  *) bad "r9 spend: cx apikey gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
printf '{"tokens":{"access_token":"x"}}' > "$HB/.codex/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate cx "" cxnative "r9 probe" 2>&1 </dev/null; _osrc_spend_gate ci "" cxnative "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -eq 0 ] && ok "r9 spend: cx + ci ChatGPT auth.json -> proceed" || bad "r9 spend: cx/ci plan gate refused (rc=$rc): $(printf '%s' "$out" | head -4)"
rm -rf "$HB/.codex"
# gm: api-key material in the login dir or a Gemini/Google key env -> metered -> refuse;
# plain dir + agy -> subscription -> proceed.
mkdir -p "$HB/.antigravity"; printf '{"apiKey":"gemini-key-abcdef123456"}' > "$HB/.antigravity/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate gm "" gmnative "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills metered"*) ok "r9 spend: gm dir apiKey -> refuse" ;;
  *) bad "r9 spend: gm dir-key gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
printf '{"auth":"session"}' > "$HB/.antigravity/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" GEMINI_API_KEY=x bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate gm "" gmnative "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills metered"*) ok "r9 spend: gm GEMINI_API_KEY -> refuse" ;;
  *) bad "r9 spend: gm env-key gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  have() { [ "$1" = agy ] && return 0; command -v "$1" >/dev/null 2>&1; }
  _osrc_spend_gate gm "" gmnative "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -eq 0 ] && ok "r9 spend: gm plain auth dir -> proceed" || bad "r9 spend: gm plan gate refused (rc=$rc): $(printf '%s' "$out" | head -4)"
rm -rf "$HB/.antigravity"
# cursor/droid/warp: api-key material -> metered -> refuse; plain auth dir + CLI -> proceed.
mkdir -p "$HB/.cursor"; printf '{"apiKey":"cursor-key-abcdef123456"}' > "$HB/.cursor/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate cursor "" cursor "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills metered"*) ok "r9 spend: cursor dir apiKey -> refuse" ;;
  *) bad "r9 spend: cursor dir-key gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
printf '{"auth":"session-token"}' > "$HB/.cursor/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  have() { case "$1" in cursor-agent|agent) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  _osrc_spend_gate cursor "" cursor "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -eq 0 ] && ok "r9 spend: cursor plain auth dir -> proceed" || bad "r9 spend: cursor plan gate refused (rc=$rc): $(printf '%s' "$out" | head -4)"
rm -rf "$HB/.cursor"
mkdir -p "$HB/.factory"; printf '{"api_key":"factory-key-abcdef123456"}' > "$HB/.factory/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate droid "" droid "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills metered"*) ok "r9 spend: droid dir api_key -> refuse" ;;
  *) bad "r9 spend: droid dir-key gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
printf '{"auth":"session"}' > "$HB/.factory/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  have() { [ "$1" = droid ] && return 0; command -v "$1" >/dev/null 2>&1; }
  _osrc_spend_gate droid "" droid "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -eq 0 ] && ok "r9 spend: droid plain auth dir -> proceed" || bad "r9 spend: droid plan gate refused (rc=$rc): $(printf '%s' "$out" | head -4)"
rm -rf "$HB/.factory"
mkdir -p "$HB/.warp"; printf '{"api-key":"warp-key-abcdef123456"}' > "$HB/.warp/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate warp "" warp "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills metered"*) ok "r9 spend: warp dir api-key -> refuse" ;;
  *) bad "r9 spend: warp dir-key gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
printf '{"auth":"session"}' > "$HB/.warp/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  have() { [ "$1" = oz ] && return 0; command -v "$1" >/dev/null 2>&1; }
  _osrc_spend_gate warp "" warp "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -eq 0 ] && ok "r9 spend: warp plain auth dir -> proceed" || bad "r9 spend: warp plan gate refused (rc=$rc): $(printf '%s' "$out" | head -4)"
rm -rf "$HB/.warp"

# unknown is treated as METERED by the gate: non-interactive refusal + EVENT approval + NEXT.
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
        _osrc_spend_gate or some-model or "test" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"EVENT approval"*"paid-lane:or/"* ) ok "r3 spend: non-interactive metered lane refuses with EVENT approval" ;;
  *) bad "r3 spend: refusal missing EVENT approval (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
case "$out" in
  *"--spend-ok"*) ok "r3 spend: refusal NEXT names --spend-ok" ;;
  *) bad "r3 spend: refusal missing --spend-ok hint: $(printf '%s' "$out" | head -4)" ;;
esac
grep -q '"kind":"approval"' "$OSRC_HOME/lanes/events.jsonl" 2>/dev/null \
  && ok "r3 spend: EVENT approval persisted to lanes/events.jsonl" \
  || bad "r3 spend: events.jsonl missing approval event"

# --spend-ok consents THIS command only: OSRC_SPEND_OK set AFTER sourcing (what flag parsing
# does) lets the gate proceed; a fresh command without it refuses again. (Env-inherited
# OSRC_SPEND_OK is sanitized by the env block — proven by the dedicated test below.)
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
        OSRC_SPEND_OK=1; _osrc_spend_gate or some-model or "test" 2>&1 </dev/null' )"; rc=$?
[ $rc -eq 0 ] && ok "r3 spend: --spend-ok (OSRC_SPEND_OK=1) consents this command" || bad "r3 spend: consented gate rc=$rc: $out"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
        _osrc_spend_gate or some-model or "test" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && ok "r3 spend: consent does NOT persist to the next command" || bad "r3 spend: consent leaked into next command"

# Env-inherited OSRC_SPEND_OK must be sanitized by the engine env block BEFORE parsing.
b=$( OSRC_SPEND_OK=1 OSRC_SOURCED=1 bash -c '. "'"$SRC"'" >/dev/null 2>&1; printf "%s" "${OSRC_SPEND_OK:-unset}"' )
[ "$b" = "unset" ] && ok "r3 spend: env OSRC_SPEND_OK is unset by the env block (cannot imply consent)" \
  || bad "r3 spend: env OSRC_SPEND_OK survived sourcing ('$b')"
# .spend-ok job marker consents (the bg one-command channel) — r3.2: accepted ONLY for a
# real job child: dir directly under $OSRC_JOBS, OSRC_JOB_TOKEN matching the marker's
# header, and an EXACT lane|model pair (never "*", never empty). Runs in the
# already-sourced shell with env-prefixes exactly as the detached child's gate reads them.
JD="$OSRC_HOME/jobs/r3job"; mkdir -p "$JD"
_mkmark() {  # <dir> <token> <pairs...>
  local d="$1" t="$2"; shift 2
  { printf '#osrc-spend-ok token=%s\n' "$t"; printf '%s\n' "$@"; } > "$d/.spend-ok"
}
# Wildcard and empty-model fields authorize NOTHING anymore.
_mkmark "$JD" tokA 'or|*'
out="$( OSRC_JOB_DIR="$JD" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or some-model or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: wildcard lane|* marker consents nothing" || bad "r3.2 spend: wildcard marker leaked consent (rc=$rc)"
_mkmark "$JD" tokA 'or|'
out="$( OSRC_JOB_DIR="$JD" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or some-model or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: empty-model marker consents nothing" || bad "r3.2 spend: empty-model marker leaked (rc=$rc)"
# Exact pair + matching token -> consent, and the gate consumes (deletes) the marker.
_mkmark "$JD" tokA 'or|some-model'
out="$( OSRC_JOB_DIR="$JD" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or some-model or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -eq 0 ] && ok "r3.2 spend: exact lane|model marker + job token consents" || bad "r3.2 spend: exact marker rc=$rc: $out"
[ ! -f "$JD/.spend-ok" ] && ok "r3.2 spend: marker consumed after dispatch" || bad "r3.2 spend: marker survived dispatch"
# Wrong token (a sibling job's secret, or a forged env) consents nothing.
_mkmark "$JD" tokB 'or|some-model'
out="$( OSRC_JOB_DIR="$JD" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or some-model or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: token mismatch consents nothing" || bad "r3.2 spend: wrong-token consent leaked (rc=$rc)"
# No token at all -> nothing (an arbitrary OSRC_JOB_DIR alone is not a job child).
out="$( OSRC_JOB_DIR="$JD" _osrc_spend_gate or some-model or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: OSRC_JOB_DIR without OSRC_JOB_TOKEN consents nothing" || bad "r3.2 spend: tokenless dir consented (rc=$rc)"
# A marker dir OUTSIDE $OSRC_JOBS is never honored, even with a valid-looking header.
OUTJ="$TMP/notjobs"; mkdir -p "$OUTJ"; _mkmark "$OUTJ" tokA 'or|some-model'
out="$( OSRC_JOB_DIR="$OUTJ" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or some-model or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: marker outside \$OSRC_JOBS consents nothing" || bad "r3.2 spend: out-of-tree marker consented (rc=$rc)"
# Nested/traversal job dirs are not "this job" either.
NEST="$OSRC_HOME/jobs/a/b"; mkdir -p "$NEST"; _mkmark "$NEST" tokA 'or|some-model'
out="$( OSRC_JOB_DIR="$NEST" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or some-model or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: nested job dir consents nothing" || bad "r3.2 spend: nested dir consented (rc=$rc)"
# Binding still holds inside the trusted context: lane `or` marker does NOT authorize `dv`,
# and a model-bound marker does not cover a different model on the same lane.
_mkmark "$JD" tokA 'or|some-model'
out="$( OSRC_JOB_DIR="$JD" OSRC_JOB_TOKEN=tokA bash -c '. "'"$SRC"'" >/dev/null 2>&1; _devin_catalog_free_ids() { return 1; }; _osrc_spend_gate dv glm-5.2 dv "test"' 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: or-marker does not authorize the dv lane" || bad "r3.2 spend: cross-lane consent leaked (rc=$rc)"
out="$( OSRC_JOB_DIR="$JD" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or hy3 or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: model-bound marker does not cover a different model" || bad "r3.2 spend: cross-model consent leaked (rc=$rc)"
_mkmark "$JD" tokA 'or|hy3'
out="$( OSRC_JOB_DIR="$JD" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or hy3 or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -eq 0 ] && ok "r3.2 spend: exact lane|model marker consents (second pair)" || bad "r3.2 spend: exact marker rc=$rc: $out"
rm -f "$JD/.spend-ok"

# Fallback pickers never select a metered lane quietly: only `or` ready -> no pick;
# with spend consent the same list picks it.
fb="$( _fallback_lane_ready() { [ "$1" = or ] && return 0; return 1; }
        _osrc_lane_spendable or m || true
        _fallback_pick "" "alias|model|or" )"
[ -z "$fb" ] && ok "r3 spend: fallback refuses to pick metered or without consent" || bad "r3 spend: fallback picked '$fb'"
fb="$( _fallback_lane_ready() { [ "$1" = or ] && return 0; return 1; }
        OSRC_SPEND_OK=1 _fallback_pick "" "alias|model|or" )"
[ "$fb" = "alias|model|or" ] && ok "r3 spend: --spend-ok lets fallback reach the paid lane" || bad "r3 spend: consented fallback -> '$fb'"
# Same for the limit-gate's own suggestion helper: paid-only -> nothing without consent, or with it.
fb="$( HOME="$FH0"; _fallback_lane_ready() { [ "$1" = or ] && return 0; return 1; }
        _lane_ready_probe() { return 1; }
        _devin_catalog_free_ids() { return 1; }; _timeout() { return 1; }
        OSRC_SPEND_OK=1 _osrc_limit_fallback "codexwk=98" )"
[ "$fb" = "or" ] && ok "r3 spend: consented limit-fallback may name the paid lane" || bad "r3 spend: consented limit-fallback -> '$fb'"
# Subscription lane still picked without consent (control).
fb="$( _fallback_lane_ready() { [ "$1" = local ] && return 0; return 1; }
        _fallback_pick "" "a1|m1|local
a2|m2|or" )"
[ "$fb" = "a1|m1|local" ] && ok "r3 spend: free lane still picked first without consent" || bad "r3 spend: free pick -> '$fb'"


echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
