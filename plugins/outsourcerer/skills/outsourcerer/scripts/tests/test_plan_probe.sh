#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_plan_probe.sh -- PL (0.16.3): every plan on the Mission Control plans card is checked on its own.
# Alex: "there IS NO EXCUSE to write 'not checked yet'." Fake CLIs on PATH (never the real ones):
#   codex   answers `app-server` JSON-RPC account/rateLimits/read (the shape the real 0.169 returns)
#   agy     a fake TUI that draws the REAL captured `/usage` screen (fixtures/agy-usage-screen.txt) when
#           `/usage` is typed; read through a private tmux server named osrc-test-PL-* with its own TMUX_TMPDIR
#   devin   `models` (real output shape) + `auth status` with a name/email the feed must never carry
#   droid   `doctor --json --checks auth` (real output shape)
#   claude  a statusline artifact 40 minutes old (stale for gating, still a floor worth showing)
# Asserts: no detected row says "not checked yet", every row has a checked-at time, each probe's numbers
# land on its row with both windows and renew times, failures say why, caches serve without re-running,
# a stale cache refreshes in the background, and the libs load when limits.sh is sourced alone.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/.."
ENG="$S/outsourcerer.sh"
FIX="$HERE/fixtures/agy-usage-screen.txt"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

T="$(mktemp -d "${TMPDIR%/}/.plan-probe.XXXXXX")" || { echo "FAIL: no scratch dir"; exit 1; }
# A unix socket path must stay under ~104 bytes, so the private tmux dir is short (removed on exit).
TX="$(mktemp -d /tmp/osrc-test-PL.XXXXXX)" || { rm -rf "$T"; echo "FAIL: no tmux dir"; exit 1; }
cleanup() {
  local s; for s in "$TX"/*/osrc-test-PL*; do [ -S "$s" ] && tmux -S "$s" kill-server 2>/dev/null; done
  rm -rf "$T" "$TX"
}
[ -n "${KEEP:-}" ] && echo "T=$T" || trap cleanup EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

H="$T/home"; B="$T/bin"; mkdir -p "$H" "$B" "$T/calls"
export HOME="$T/home"   # never the developer's HOME (test_tests_set_home)
for t in jq python3 tmux; do p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$B/$t"; done

# ---- fake CLIs ---------------------------------------------------------------------------------
NOW="$(date +%s)"; WK_RESET=$(( NOW + 4 * 86400 )); H5_RESET=$(( NOW + 3 * 3600 ))
cat > "$B/codex" <<EOF
#!/bin/sh
echo codex >> "$T/calls/codex"
case "\$1" in
  login) echo "Logged in using ChatGPT"; exit 0 ;;
  app-server)
    while IFS= read -r l; do
      case "\$l" in
        *'"initialize"'*) echo '{"id":1,"result":{"userAgent":"fake"}}'; echo '{"method":"configWarning","params":{}}' ;;
        *'rateLimits/read'*)
          [ -f "$T/codex-down" ] && { echo '{"id":2,"error":{"code":-1,"message":"not signed in"}}'; exit 0; }
          echo '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":$WK_RESET},"secondary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":$H5_RESET},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"prolite","rateLimitReachedType":null},"rateLimitResetCredits":{"availableCount":3}}}' ;;
      esac
    done ;;
esac
exit 0
EOF
cat > "$B/devin" <<EOF
#!/bin/sh
echo "\$*" >> "$T/calls/devin"
case "\$*" in
  models) cat <<'M'
Available models (3 families)

SWE-2 (swe-2)
  aliases: swe
  swe-2-high                                                                 SWE-2 High  [262K context, Free]
  swe-2-medium                                                               SWE-2 Medium  [262K context, Free]
  swe-2-max-lightning                                                        SWE-2 Max Lightning  [262K context, \$1 / 1M Input · \$5 / 1M Output]

Fusion (fusion)
  fusion-claude-opus-5-5-medium-sidekick-swe-2-medium                        Fusion (Opus + SWE-2)  [1M context, \$4 / 1M Input · Sidekick: Free]
M
  ;;
  "auth status") printf 'Logged in (via Devin).\n\nUser:\n  Name:              Fixture Person\n  Email:             fixture@example.invalid\n\nAccount:\n  Tier:              Devin Pro\n  Plan:              Pro\n' ;;
esac
exit 0
EOF
cat > "$B/droid" <<'EOF'
#!/bin/sh
case "$*" in *doctor*) cat <<'J'
{"generatedAt":"2026-11-16T08:07:16.830Z","ok":true,"results":[{"id":"auth.credentials","category":"auth","label":"Credential storage read","status":"pass","detail":"stored login session loaded from credential storage"},{"id":"auth.tokenExpiry","category":"auth","label":"Access token expiry","status":"pass","detail":"access token valid until 2026-11-17T08:02:30.000Z; this run does not exercise the api.workos.com token refresh"}]}
J
;; esac
exit 0
EOF
# agy: a fake TUI. Draws a composer with placeholder text (as 1.5.9 does), and on `/usage` the real screen.
cat > "$B/agy" <<EOF
#!/bin/sh
echo agy >> "$T/calls/agy"
printf '%s\n' '────────────────────────────────────────' '> Auto mode: edits & safe commands auto-approved (shift+tab to cycle)' '────────────────────────────────────────'
while IFS= read -r l; do
  case "\$l" in *usage*) clear 2>/dev/null; cat "$FIX"; sleep 30; exit 0 ;; esac
done
EOF
printf '#!/bin/sh\n[ "$1 $2" = "auth status" ] && echo '"'"'{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'"'"'\nexit 0\n' > "$B/claude"
chmod +x "$B"/codex "$B"/devin "$B"/droid "$B"/agy "$B"/claude

# Auth evidence (file names only; contents are placeholders) so each harness is DETECTED.
mkdir -p "$H/.claude/token-optimizer" "$H/.codex" "$H/.antigravity" "$H/.factory"
printf '{}' > "$H/.claude/.credentials.json"; printf '{"tokens":{}}' > "$H/.codex/auth.json"; printf '{}' > "$H/.factory/auth.json"
# Claude statusline artifact, 40 minutes old: stale for the gate (10 min), still worth showing with its age.
printf '{"five_hour":{"used_percentage":30,"resets_at":%s},"seven_day":{"used_percentage":23,"resets_at":%s},"timestamp":%s000,"source":"statusline"}\n' \
  "$(( NOW + 7200 ))" "$WK_RESET" "$(( NOW - 2400 ))" > "$H/.claude/token-optimizer/rate-limits.json"

# _feed [VAR=val ...] -> osrc_lane_summary --json in a hermetic env (fake HOME + fake-only PATH).
_feed() {
  env -i HOME="$H" PATH="$B:/usr/bin:/bin" OSRC_PLATFORM=linux OSRC_HOME="$T/osrc" OSRC_SOURCED=1 TERM=dumb \
      TMUX_TMPDIR="$TX" OSRC_PROBE_TMUX_PREFIX=osrc-test-PL OSRC_PROBE_AGY_SECS=12 "$@" \
      bash -c '. "$1"; _ready_probe_local() { return 1; }; osrc_lane_summary --json' _ "$ENG" 2>/dev/null
}
row() { jq -c --arg i "$1" '.[] | select(.id == $i)' <<<"$J"; }
mkdir -p "$T/osrc"

# ---- 1. the live feed -------------------------------------------------------------------------
J="$(_feed)"
jq -e 'arrays and length >= 5' >/dev/null 2>&1 <<<"$J" && ok "feed: valid array with every detected harness" || bad "feed: bad JSON: $J"
for id in claude codex agy devin droid; do [ -n "$(row "$id")" ] && ok "feed: $id detected" || bad "feed: $id missing"; done
grep -qi 'not checked yet' <<<"$J" && bad "feed: a row still says 'not checked yet'" || ok "feed: no row says 'not checked yet'"
jq -e 'all(.[]; (.left // "") != "" and (.updated // "") != "")' >/dev/null <<<"$J" && ok "feed: every row has a left text and a checked-at time" || bad "feed: a row lacks left/updated: $J"
jq -e 'all(.[]; .state != "wait" or (.renews_at | type) == "number")' >/dev/null <<<"$J" && ok "feed: no 'Waiting for reset' without a reset time" || bad "feed: wait without renews_at"

R="$(row codex)"
jq -e '.state == "ok" and .left == "59% left" and .windows.codexwk.left == 59 and .windows.codex5h.left == 88 and (.windows.codex5h.renews_at | type) == "number" and (.windows.codexwk.renews_at | type) == "number"' >/dev/null <<<"$R" \
  && ok "codex: app-server reading with BOTH windows and their reset times" || bad "codex: $R"
jq -e '(.note | test("codex app-server")) and (.note | test("prolite"))' >/dev/null <<<"$R" && ok "codex: note names the live source and plan" || bad "codex note: $R"

R="$(row agy)"
# The agy probe reads its screen through tmux; with no tmux on the machine it must say why, not guess.
if [ ! -e "$B/tmux" ]; then
  echo "SKIP: tmux not installed, agy /usage screen checks skipped"
  jq -e '.left == "No reading" and (.note | test("could not be read"))' >/dev/null <<<"$R" && ok "agy: no tmux -> No reading with the reason" || bad "agy no-tmux: $R"
else
jq -e '.state == "out" and .left == "0% left · Claude and GPT Models" and .renews_at != null and .plan_seen == true and (.windows | length) == 5' >/dev/null <<<"$R" && ok "agy: headline is the tightest window across groups, named, with its refresh (Gemini 100% never hides Claude and GPT at 0%)" || bad "agy: $R"
jq -e '[.windows[] | select(.label == "Claude and GPT Models · week")][0] | .left == 0 and (.renews_at | type) == "number" and .renews_at > now + 3*86400' >/dev/null <<<"$R" \
  && ok "agy: spent group keeps its refresh time (Refreshes in 94h 19m)" || bad "agy windows: $R"
jq -e '.note | test("Claude and GPT Models: 0% left")' >/dev/null <<<"$R" && ok "agy: note names the other groups" || bad "agy note: $R"
fi
grep -q '@' <<<"$R" && bad "agy: an account email leaked into the feed" || ok "agy: no account email in the feed"
if [ -n "$(ls "$TX"/*/ 2>/dev/null | grep -v '^osrc-test-PL' || true)" ]; then bad "agy: probe used a tmux socket not named osrc-test-PL*"; else ok "agy: probe tmux server is private and test-named"; fi

R="$(row devin)"
jq -e '.state == "ok" and .left == "Free · no limit" and (.note | test("Pro plan: 2 models are free")) and (.note | test("cloud quota"))' >/dev/null <<<"$R" && ok "devin: Free · no limit + cloud quota note, Pro plan, only true Free rows counted" || bad "devin: $R"
grep -qE 'fixture@example|Fixture Person' <<<"$J" && bad "devin: name/email leaked" || ok "devin: name and email never leave the probe"

R="$(row droid)"
jq -e '.state == "ok" and .left == "Pay per use" and (.note | test("Signed in to Factory")) and (.note | test("No cap set"))' >/dev/null <<<"$R" && ok "droid: pay per use, sign-in proven, no cap" || bad "droid: $R"

R="$(row claude)"
jq -e '.left == "70% left" and .windows.claude5h.left == 70 and .windows.claude7d.left == 77 and (.note | test("Last reading 40 min ago"))' >/dev/null <<<"$R" \
  && ok "claude: stale statusline still shows both windows with the reading's age" || bad "claude: $R"
jq -e '.windows.claude5h.renews != null and .windows.claude7d.renews != null' >/dev/null <<<"$R" && ok "claude: each window carries its renew text" || bad "claude renews: $R"

# ---- 2. caching: fresh cache never re-runs the CLI ------------------------------------------------
c1="$(wc -l < "$T/calls/codex")"; a1="$(wc -l < "$T/calls/agy")"
J="$(_feed)"
[ "$(wc -l < "$T/calls/agy")" = "$a1" ] && ok "cache: fresh agy answer served without a second TUI" || bad "cache: agy re-ran"
c2="$(wc -l < "$T/calls/codex")"; [ $(( c2 - c1 )) -le 1 ] && ok "cache: fresh codex answer served (only the login probe ran)" || bad "cache: codex re-ran $((c2-c1))x"

# ---- 3. stale cache: served at once, refreshed in the background --------------------------------
touch -t 202601010000 "$T/osrc/hub/probes/codex.json"
d0="$(wc -l < "$T/calls/codex")"
J="$(_feed)"
jq -e '.[] | select(.id == "codex") | .left == "59% left"' >/dev/null <<<"$J" && ok "stale cache: old answer served immediately" || bad "stale cache: $(row codex)"
_m() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ ! -d "$T/osrc/hub/probes/codex.lock" ] && [ "$(_m "$T/osrc/hub/probes/codex.json")" -gt $(( NOW - 120 )) ] && break; sleep 1; done
m="$(_m "$T/osrc/hub/probes/codex.json")"
[ "$m" -gt $(( NOW - 120 )) ] && [ "$(wc -l < "$T/calls/codex")" -gt "$d0" ] && ok "stale cache: background refresh rewrote it" || bad "stale cache: no background refresh (mtime $m)"

# ---- 4. failures say why, never 'not checked yet' -------------------------------------------------
: > "$T/codex-down"; rm -f "$T/osrc/hub/probes/codex.json"
J="$(_feed OSRC_PROBE_TTL_CODEX=0)"
jq -e '.[] | select(.id == "codex") | .state == "unknown" and .left == "No reading" and (.note | test("not signed in"))' >/dev/null <<<"$J" \
  && ok "failure: codex refusal shows No reading + the reason" || bad "failure codex: $(row codex)"
rm -f "$T/codex-down"
J="$(_feed OSRC_PROBE=0)"
grep -qi 'not checked yet' <<<"$J" && bad "probes off: 'not checked yet' came back" || ok "probes off: rows still say what is known"
jq -e 'all(.[]; (.left // "") != "")' >/dev/null <<<"$J" && ok "probes off: every row has a left text" || bad "probes off: empty left: $J"

# ---- 5. units: parsers and the overlay's last pass -------------------------------------------------
P="$S/lib/plan_probe.py"
U="$(python3 -I "$P" agy-parse 1794816644 < "$FIX")"
jq -e '.ok and (.groups | length) == 3 and .groups[1].windows[0].left == 0 and .groups[1].windows[0].renews_at == (1794816644 + 94*3600 + 19*60) and .groups[1].windows[1].disabled' >/dev/null <<<"$U" \
  && ok "agy-parse: real screen -> 3 groups, spent group with refresh time, paused 5h" || bad "agy-parse: $U"
U="$(printf 'nothing here\n' | python3 -I "$P" agy-parse)"; jq -e '.ok == false and (.why | length) > 0' >/dev/null <<<"$U" && ok "agy-parse: no screen -> ok:false with a reason" || bad "agy-parse fail: $U"
U="$(printf '[{"id":"codex","name":"Codex","state":"wait","left":"x"}]' | jq -c --argjson p '{}' --argjson now 1 --argjson lt 90 --argjson ct 50 -f "$S/lib/plan-overlay.jq")"
jq -e '.[0].state != "wait" and .[0].left == "No reading"' >/dev/null <<<"$U" && ok "overlay: wait without a reset time never reaches the page" || bad "overlay wait: $U"
U="$(printf '[{"id":"warp","name":"Warp","state":"unknown","left":"not checked yet"}]' | jq -c --argjson p '{}' --argjson now 1 --argjson lt 90 --argjson ct 50 -f "$S/lib/plan-overlay.jq")"
jq -e '.[0].left == "No usage meter" and (.[0].note | test("Warp"))' >/dev/null <<<"$U" && ok "overlay: unmetered harness says so, with a reason" || bad "overlay generic: $U"

# ---- 6. loads when limits.sh / hub.sh are sourced alone -------------------------------------------
( . "$S/lib/limits.sh" >/dev/null 2>&1; type _osrc_plan_overlay >/dev/null 2>&1 ) && ok "load: limits.sh alone brings the plan probes" || bad "load: limits.sh alone lacks _osrc_plan_overlay"
( . "$S/lib/hub.sh" >/dev/null 2>&1; . "$S/lib/limits.sh" >/dev/null 2>&1; type _osrc_probe_kick >/dev/null 2>&1 ) && ok "load: hub.sh + limits.sh compose" || bad "load: hub.sh + limits.sh"

# ---- 7. page contract ----------------------------------------------------------------------------
HT="$S/lib/hub.html"
grep -q 'assets/hub-plans.js' "$HT" && ok "page: loads hub-plans.js" || bad "page: hub-plans.js not loaded"
grep -qi "Not checked yet" "$HT" "$S/lib/hub-assets/"*.js && bad "page: 'Not checked yet' label still present" || ok "page: no 'Not checked yet' label"
grep -q "nm.append(hlogo(l), el('span', 'nmt'" "$HT" && ok "page: icon sits inline before the name" || bad "page: icon not inline"
if command -v node >/dev/null 2>&1; then
  N="$(node -e '
    global.window = {}; require(process.argv[1]);
    const el = (t, c, x) => ({ t, c, x, kids: [], title: "", append(...k) { this.kids.push(...k); } });
    global.document = { createTextNode: (s) => ({ text: s }) };
    const P = window.OSRC_HUB_PLANS, now = Math.floor(Date.now() / 1000);
    const one = P.windows({ windows: { claude7d: { left: 77, renews_at: now + 9000 } } }, el, null);
    const two = P.windows({ windows: { claude5h: { left: 70, renews_at: now + 3600 }, claude7d: { left: 77, renews_at: now + 90000 } } }, el, null);
    console.log(JSON.stringify({ one, lines: two ? two.kids.length : 0, label: two && two.kids[0].kids[0].x, renew: P.renew(now + 60).startsWith("today") }));
  ' "$S/lib/hub-assets/hub-plans.js" 2>&1)"
  jq -e '.one == null and .lines == 2 and .label == "5 hours" and .renew' >/dev/null 2>&1 <<<"$N" && ok "page: two windows -> two lines with labels and renew text" || bad "page helper: $N"
else echo "SKIP: node not installed (page helper)"; fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
