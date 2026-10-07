#!/usr/bin/env bash
# test_lane_plan_limit.sh — GENERIC per-lane plan-limit detection. Pins: (a) the dispatcher
# routes dv to the Devin matcher and every other subscription lane to its own CONTEXT-ANCHORED matcher,
# each grounded in that CLI's real refusal wording: a real-shaped refusal matches, unrelated prose /
# transient per-minute 429s / context-window errors do NOT, and a lane with no matcher (hermes/or/
# local/unknown) is a non-match, never a false positive; (b) the generic reset-phrase parser returns the
# lane's OWN stated reset ("Try again in 9h 41m", "will reset at 3pm", "resets 4pm", the headless
# claude epoch form) or stays empty — never a wrong number; (c) _lane_free_probe recipes: cx/cc confirm
# via their own meter (limit-refused only at >=100%), lanes with no recipe -> unreachable rc2; (d) the
# generic block is probe-then-decide: meter-confirmed -> lane down for the stated reset (+slack) with a
# recorded reason; no recipe / inconclusive -> only the short self-healing window; dv routes to its own
# block; (e) the after-run hook fires only on a failed run (or a headless is_error:true result) AND a
# match; (f) the per-lane jobs meter counts a lane's ledger rows and the brief/status meter iterates
# every plan lane; (g) structurally, every plan-lane delegate calls the hook.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"; export HOME="$TMP"
cleanup() { rm -rf "$TMP"; }; trap cleanup EXIT
. "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
_quota_note_refusal() { :; }   # declared-cap reconcile is a no-op here; keep this test about detection + the lane

# --- fixtures: real-shaped refusal wording per CLI (see the grounding block in the script) ---------
FX="$TMP/fx"; mkdir -p "$FX"
_future=$(( $(date +%s) + 7200 ))
printf "Error: You've hit your usage limit. Try again in 2h 15m.\n"                                  > "$FX/cx-hit"
printf 'codex: usage limit reached\n'                                                                > "$FX/cx-reached"
printf 'Error: stream disconnected before completion: 502 Bad Gateway\nretrying...\n'                > "$FX/cx-no"
printf 'warning: token limit for context reached, compacting conversation\n'                         > "$FX/cx-no2"
printf 'Claude usage limit reached. Your limit will reset at 3pm (America/Santiago).\n'              > "$FX/cc-hit"
printf '{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached|%s"}\n' "$_future" > "$FX/cc-json"
printf "You've hit your limit · resets 4pm (Asia/Kuala_Lumpur)\n"                                   > "$FX/cc-short"
printf 'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"}}\n' > "$FX/cc-no"
printf 'Prompt is too long: 250000 tokens > 200000 maximum\n'                                        > "$FX/cc-no2"
printf "You've hit your usage limit. Switch to Auto for more usage or set a Spend Limit to continue with Sonnet. Your usage limits will reset when your monthly cycle ends on 10/1/2026.\n" > "$FX/cursor-hit"
printf 'fallbackModel: default\nspendLimitHit: true\n'                                               > "$FX/cursor-spend"
printf 'fallbackModel: default\nspendLimitHit: false\nError: model context window exceeded\n'        > "$FX/cursor-no"
printf "I'm sorry, I couldn't complete that request. Request failed with error: QuotaLimit\n"         > "$FX/warp-hit"
printf "You've exceeded your monthly credit limit. Premium models will be disabled until your quota resets at the start of your next billing cycle.\n" > "$FX/warp-credit"
printf "Message token limit exceeded: your input plus attached context exceeds the model's context window.\n" > "$FX/warp-no"
printf 'oz: agent run failed: connection reset by peer\n'                                            > "$FX/warp-no2"
printf 'Error: Rate Limit reached for your plan. Run /limits to toggle Droid Core or Extra Usage and retry.\n' > "$FX/droid-hit"
printf 'Your included usage is exhausted for this 5-hour window.\n'                                  > "$FX/droid-usage"
printf 'Error: request timed out after 60s\n'                                                        > "$FX/droid-no"
printf "Error: model 'kimi-k3' not found in catalog\n"                                               > "$FX/droid-no2"
printf '{"error":{"code":"INFERENCE_CAP_ERROR","message":"Error 429: Daily free limit reached on model z-ai/glm-5.3-flash. Try again in 9h 41m"}}\n' > "$FX/cline-hit"
printf '429 {"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"}}\n' > "$FX/cline-no"
printf 'Task completed. 3 files edited.\n'                                                           > "$FX/cline-no2"
printf 'Error: Connection error\nexhausted all retry attempts\nrate: 3 files/s, limit: none, quota: n/a\n' > "$FX/unrelated"
printf 'Error: Your daily usage quota has been exhausted. It resets in 11h26m. See https://app.devin.ai/settings/usage\n' > "$FX/dv-daily"
printf 'Error: 402 Payment Required — 0%% remaining ACU balance\n'                                   > "$FX/dv-acu"
: > "$FX/empty"

# === (a) dispatcher + per-lane matchers ==========================================================
hit() { _lane_plan_limit_refusal "$1" "$FX/$2" && ok "match: $1 <- '$2' is a plan-limit refusal" || bad "match: $1 <- '$2' NOT recognized"; }
miss() { _lane_plan_limit_refusal "$1" "$FX/$2" && bad "match: $1 <- '$2' wrongly read as a plan-limit refusal" || ok "match: $1 <- '$2' is NOT a plan-limit refusal"; }
hit cx cx-hit;        hit cx cx-reached;        miss cx cx-no;      miss cx cx-no2
hit cc cc-hit;        hit cc cc-json;   hit cc cc-short;  miss cc cc-no;      miss cc cc-no2
hit cursor cursor-hit; hit cursor cursor-spend;             miss cursor cursor-no
hit warp warp-hit;    hit warp warp-credit;       miss warp warp-no;  miss warp warp-no2
hit droid droid-hit;  hit droid droid-usage;      miss droid droid-no; miss droid droid-no2
hit cline cline-hit;                              miss cline cline-no; miss cline cline-no2
hit dv dv-daily;      hit devin dv-daily;         miss dv dv-acu
for l in dv cx cc cursor warp droid cline; do miss "$l" unrelated; miss "$l" warp-no; miss "$l" empty; done
for l in hermes or local gm nope ''; do
  _lane_plan_limit_refusal "$l" "$FX/cx-hit" && bad "unknown lane '$l' matched (false positive)" || ok "unknown/no-matcher lane '${l:-<empty>}' -> non-match"
done
[ "$(_lane_plan_key cc)" = "cc" ] && ok "key: 'cc' in lane context is the Claude-native lane (not or's provider)" || bad "key: cc -> '$(_lane_plan_key cc)'"
[ "$(_lane_plan_key devin)" = "dv" ] && ok "key: 'devin' folds to dv" || bad "key: devin -> '$(_lane_plan_key devin)'"
[ "$(_lane_plan_key cxnative)" = "cx" ] && ok "key: disp 'cxnative' folds to cx" || bad "key: cxnative -> '$(_lane_plan_key cxnative)'"
[ -z "$(_lane_plan_key '?')" ] && ok "key: '?' -> empty" || bad "key: '?' -> '$(_lane_plan_key '?')'"
case "$(_lane_plan_limit_line cc "$FX/cc-hit")" in "Claude usage limit reached"*) ok "line: cc wording surfaced" ;; *) bad "line: got '$(_lane_plan_limit_line cc "$FX/cc-hit")'" ;; esac
case "$(_lane_plan_limit_line dv "$FX/dv-daily")" in *"daily usage quota"*) ok "line: dv routes to the Devin line extractor" ;; *) bad "line: dv -> '$(_lane_plan_limit_line dv "$FX/dv-daily")'" ;; esac
[ -z "$(_lane_plan_limit_line hermes "$FX/cx-hit")" ] && ok "line: no-matcher lane -> empty" || bad "line: hermes produced a line"

# === (b) reset phrase + seconds: the lane's own words or nothing ==================================
rp() { # <fixture> <expected-phrase-ci|EMPTY>
  local got; got="$(_lane_limit_reset_phrase "$FX/$1")"
  if [ "$2" = EMPTY ]; then [ -z "$got" ] && ok "phrase: '$1' -> empty" || bad "phrase: '$1' -> '$got' (want empty)"
  else [ "$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" ] && ok "phrase: '$1' -> '$got'" || bad "phrase: '$1' -> '$got' (want '$2')"; fi
}
rp cx-hit    "Try again in 2h 15m"
rp cline-hit "Try again in 9h 41m"
rp cc-hit    "will reset at 3pm (America/Santiago"   # body stops at the closing paren, like the Devin extractor
rp cc-short  "resets 4pm"
rp cc-json   "usage limit reached|$_future"
rp cursor-hit EMPTY
rp dv-daily  "resets in 11h26m"
rp unrelated EMPTY
rs() { # <fixture> <min> <max> | <fixture> EMPTY
  local ph got; ph="$(_lane_limit_reset_phrase "$FX/$1")"; got="$(_lane_limit_reset_secs "$ph")"
  if [ "$2" = EMPTY ]; then [ -z "$got" ] && ok "secs: '$1' -> empty (no wrong number)" || bad "secs: '$1' -> '$got' (want empty)"; return; fi
  case "$got" in ''|*[!0-9]*) bad "secs: '$1' -> '$got' (want $2..$3)"; return ;; esac
  [ "$got" -ge "$2" ] && [ "$got" -le "$3" ] && ok "secs: '$1' -> ${got}s" || bad "secs: '$1' -> ${got}s (want $2..$3)"
}
rs cx-hit    8100 8100
rs cline-hit 34860 34860
rs cc-hit    1 86400
rs cc-short  1 86400
rs cc-json   7000 7200   # fixture epoch was stamped at suite start; earlier bounded probes ate some seconds
rs dv-daily  41160 41160
rs cursor-hit EMPTY
rs unrelated EMPTY
[ -z "$(_lane_limit_reset_secs 'usage limit reached|1749924000')" ] && ok "secs: past epoch -> empty" || bad "secs: past epoch produced a number"
[ -z "$(_lane_limit_reset_secs 'try again in a moment')" ] && ok "secs: unparseable 'try again' -> empty" || bad "secs: garbage produced a number"

# === (c) probe recipes ============================================================================
for l in warp droid cursor cline gm; do
  _v="$(_lane_free_probe "$l")"; _rc=$?
  [ "$_v" = unreachable ] && [ "$_rc" -eq 2 ] && ok "probe: $l has no recipe -> unreachable rc=2" || bad "probe: $l -> '$_v' rc=$_rc"
done
_session_limits() { printf 'codex5h=100 codexwk=42\n'; }
_v="$(_lane_free_probe cx)"; _rc=$?; [ "$_v" = limit-refused ] && [ "$_rc" -eq 0 ] && ok "probe: cx meter at 100% -> limit-refused" || bad "probe: cx -> '$_v' rc=$_rc"
grep -q 'codex5h=100' "$(_lane_probe_file cx)" 2>/dev/null && ok "probe: cx meter tokens captured for quoting (PID-scoped file)" || bad "probe: cx capture missing at $(_lane_probe_file cx)"
_v="$(_lane_free_probe cc)"; _rc=$?; [ "$_v" = unreachable ] && [ "$_rc" -eq 0 ] && ok "probe: cc with no claude tokens -> unreachable rc=0 (inconclusive, not 'no recipe')" || bad "probe: cc -> '$_v' rc=$_rc"
_session_limits() { printf 'claude5h=100 claude7d=61\n'; }
[ "$(_lane_free_probe cc)" = limit-refused ] && ok "probe: cc meter at 100% -> limit-refused" || bad "probe: cc -> '$(_lane_free_probe cc)'"
_session_limits() { printf 'codex5h=99.5 codexwk=100\n'; }
[ "$(_lane_free_probe cx)" = limit-refused ] && ok "probe: cx weekly at 100% -> limit-refused" || bad "probe: cx wk -> '$(_lane_free_probe cx)'"
_session_limits() { printf 'codex5h=99.5 codexwk=40\n'; }
[ "$(_lane_free_probe cx)" = unreachable ] && ok "probe: cx at 99.5% -> unreachable (never 'answered' from a meter)" || bad "probe: cx 99.5 -> '$(_lane_free_probe cx)'"
_session_limits() { :; }
[ "$(_lane_free_probe cx)" = unreachable ] && ok "probe: cx with no meter -> unreachable" || bad "probe: cx no-meter -> '$(_lane_free_probe cx)'"

# === (d) generic block: probe-then-decide ==========================================================
_session_limits() { printf 'codex5h=100 codexwk=42\n'; }
_lane_down_clear cx; _before=$(date +%s)
_out="$(_lane_plan_limit_block cx "$FX/cx-hit" gpt-5.6 'Route to Claude Code or a plan lane that is up.' 2>&1)"
_lane_down_active cx && ok "block cx: lane DOWN after meter confirmation" || bad "block cx: lane not down"
[ "$(_lane_down_reason cx)" = "plan limit exhausted" ] && ok "block cx: reason recorded" || bad "block cx: reason '$(_lane_down_reason cx)'"
_ev="$(_posture_get cx down-evidence 2>/dev/null)"
printf '%s' "$_ev" | grep -q 'usage limit' && ok "block cx: down-evidence keeps the refusal wording" || bad "block cx: down-evidence '$_ev'"
printf '%s' "$_ev" | grep -q 'probe: codex5h=100' && ok "block cx: down-evidence keeps the probe/meter proof" || bad "block cx: evidence missing probe half '$_ev'"
_until="$(_posture_get cx down 2>/dev/null)"; _ttl=$(( ${_until:-0} - _before ))
[ "$_ttl" -ge 8160 ] && [ "$_ttl" -le 8170 ] && ok "block cx: window = Codex's own 2h 15m (+slack), got ${_ttl}s" || bad "block cx: TTL ${_ttl}s"
printf '%s' "$_out" | grep -q 'Codex (ChatGPT plan) refused "gpt-5.6"' && ok "block cx: names lane + model" || bad "block cx: header missing"
printf '%s' "$_out" | grep -q 'says "Try again in 2h 15m"' && ok "block cx: quotes the lane's own reset" || bad "block cx: reset not quoted"
printf '%s' "$_out" | grep -q 'CONFIRMED' && ok "block cx: CONFIRMED verdict" || bad "block cx: verdict missing"
printf '%s' "$_out" | grep -q 'until its stated reset' && ok "block cx: window labeled as the stated reset (not an estimate)" || bad "block cx: label missing"
printf '%s' "$_out" | grep -q 'Route to Claude Code' && ok "block cx: caller's advice printed" || bad "block cx: advice missing"
printf '%s' "$_out" | grep -qi 'do NOT retry' && bad "block cx: 'do NOT retry' wording" || ok "block cx: no 'do NOT retry' wording"
_lane_down_clear cx
_session_limits() { printf 'codex5h=40\n'; }
_before=$(date +%s)
_out="$(_lane_plan_limit_block cx "$FX/cx-reached" gpt-5.6 2>&1)"
_until="$(_posture_get cx down 2>/dev/null)"; _ttl=$(( ${_until:-0} - _before ))
[ "$_ttl" -ge 1 ] && [ "$_ttl" -le 310 ] && ok "block cx (meter 40%): INCONCLUSIVE -> short window only (${_ttl}s; 300s + probe time)" || bad "block cx inconclusive: TTL ${_ttl}s"
case "$(_lane_down_reason cx)" in *"probe inconclusive"*) ok "block cx inconclusive: honest reason" ;; *) bad "block cx inconclusive: reason '$(_lane_down_reason cx)'" ;; esac
printf '%s' "$_out" | grep -q 'INCONCLUSIVE' && ok "block cx inconclusive: says so" || bad "block cx inconclusive: verdict missing"
printf '%s' "$_out" | grep -q 'gave no reset time' && ok "block cx inconclusive: no reset -> says so, no invented time" || bad "block cx: invented a reset"
_lane_down_clear cx
_before=$(date +%s)
_out="$(OSRC_LANE_PLAN_DOWN_TTL=9999 _lane_plan_limit_block warp "$FX/warp-credit" auto 2>&1)"
_lane_down_active warp && ok "block warp: refused lane gets a marker" || bad "block warp: no marker"
_until="$(_posture_get warp down 2>/dev/null)"; _ttl=$(( ${_until:-0} - _before ))
[ "$_ttl" -ge 1 ] && [ "$_ttl" -le 310 ] && ok "block warp (no recipe): UNVERIFIED -> short window (${_ttl}s; 300s + probe time), never the plan TTL" || bad "block warp: TTL ${_ttl}s"
case "$(_lane_down_reason warp)" in *"unverified: no probe recipe"*) ok "block warp: reason says unverified/no recipe" ;; *) bad "block warp: reason '$(_lane_down_reason warp)'" ;; esac
printf '%s' "$_out" | grep -q 'Warp (Oz) refused "auto"' && ok "block warp: display name" || bad "block warp: header missing"
printf '%s' "$_out" | grep -q 'UNVERIFIED' && ok "block warp: UNVERIFIED verdict" || bad "block warp: verdict missing"
printf '%s' "$_out" | grep -q 'exact wording' && ok "block warp: quotes Warp's wording" || bad "block warp: wording not quoted"
_lane_down_clear warp
# dv routes to the Devin block (probe-then-decide with a real bounded devin call -> fake devin on PATH).
FB="$TMP/fakebin"; mkdir -p "$FB"
printf '#!/usr/bin/env bash\nprintf "Error: Your daily usage quota has been exhausted. It resets in 11h26m.\\n" >&2; exit 1\n' > "$FB/devin"
chmod +x "$FB/devin"; export PATH="$FB:$PATH"
_lane_down_clear dv; _before=$(date +%s)
_out="$(_lane_plan_limit_block dv "$FX/dv-daily" glm-5.2 2>&1)"
_lane_down_active dv && ok "block dv: routes to the Devin block (lane down after a refused probe)" || bad "block dv: not down"
_until="$(_posture_get dv down 2>/dev/null)"; _ttl=$(( ${_until:-0} - _before ))
[ "$_ttl" -ge 41160 ] && [ "$_ttl" -le 41230 ] && ok "block dv: Devin's 11h26m window (+slack)" || bad "block dv: TTL ${_ttl}s"
printf '%s' "$_out" | grep -q 'Switch lanes OFF Devin' && ok "block dv: default OFF-Devin advice" || bad "block dv: advice missing"
_lane_down_clear dv
_lane_plan_limit_block nope "$FX/cx-hit" m 2>/dev/null; _lane_down_active nope && bad "block: unknown lane got a marker" || ok "block: unknown lane -> no-op"

# === (e) after-run hook ===========================================================================
_session_limits() { printf 'codex5h=100\n'; }
_lane_down_clear cx
_lane_plan_limit_after_run cx "$FX/cx-hit" gpt-5.6 0 2>/dev/null
_lane_down_active cx && bad "hook: rc=0 (no is_error) fired the block" || ok "hook: rc=0 + plain text -> nothing"
_lane_plan_limit_after_run cx "$FX/cx-no" gpt-5.6 1 2>/dev/null
_lane_down_active cx && bad "hook: rc=1 + no match fired the block" || ok "hook: rc=1 + no match -> nothing"
_lane_plan_limit_after_run cx "$FX/empty" gpt-5.6 1 2>/dev/null
_lane_down_active cx && bad "hook: empty file fired the block" || ok "hook: empty file -> nothing"
_lane_plan_limit_after_run cx "$FX/cx-hit" gpt-5.6 1 2>/dev/null
_lane_down_active cx && ok "hook: rc=1 + match -> block ran (cx down)" || bad "hook: rc=1 + match did not run the block"
[ -s "$FX/cx-hit" ] && ok "hook: does not delete the caller's file" || bad "hook: deleted the file"
_lane_down_clear cx
_session_limits() { :; }
_lane_plan_limit_after_run cc "$FX/cc-json" opus 0 2>/dev/null
_lane_down_active cc && ok "hook: headless claude rc=0 + is_error:true -> block ran" || bad "hook: is_error:true with rc=0 ignored"
case "$(_lane_down_reason cc)" in *"inconclusive"*) ok "hook cc: no meter -> short inconclusive window, not the epoch window" ;; *) bad "hook cc: reason '$(_lane_down_reason cc)'" ;; esac
_lane_down_clear cc

# === (f) per-lane jobs meter + brief/status iterator ==============================================
_now=$(date +%s)
{
  printf '{"lane":"warp","provider":"warp","model":"auto","verb":"run","epoch":%s}\n' "$_now"
  printf '{"lane":"warp","provider":"warp","model":"auto","verb":"edit","epoch":%s}\n' "$_now"
  printf '{"lane":"warp","provider":"warp","model":"auto","verb":"fallback","epoch":%s}\n' "$_now"
  printf '{"lane":"warp","provider":"warp","model":"auto","verb":"run","epoch":%s}\n' "$(( _now - 3*86400 ))"
  printf '{"provider":"codex-native","model":"gpt-5.6","verb":"run","epoch":%s}\n' "$_now"
  printf '{"lane":"cc","provider":"claude-native","model":"opus","verb":"run","epoch":%s}\n' "$_now"
  printf '{"lane":"or","provider":"codex","model":"gpt-5.6","verb":"run","epoch":%s}\n' "$_now"
  printf 'not json at all\n'
} > "$OSRC_LEDGER"
if have jq; then
  [ "$(_lane_plan_jobs_today warp)" = "2" ] && ok "meter: warp counts 2 (fallback verb + 3-day-old row excluded)" || bad "meter: warp=$(_lane_plan_jobs_today warp)"
  [ "$(_lane_plan_jobs_today cx)" = "1" ] && ok "meter: cx counts the codex-native row, not the OpenRouter-transport row" || bad "meter: cx=$(_lane_plan_jobs_today cx)"
  [ "$(_lane_plan_jobs_today cc)" = "1" ] && ok "meter: cc counts its row" || bad "meter: cc=$(_lane_plan_jobs_today cc)"
  [ "$(_lane_plan_jobs_today cursor)" = "0" ] && ok "meter: cursor 0" || bad "meter: cursor=$(_lane_plan_jobs_today cursor)"
  [ "$(_lane_plan_jobs_today nope)" = "0" ] && ok "meter: unknown lane 0" || bad "meter: nope=$(_lane_plan_jobs_today nope)"
  _l="$(_lane_plan_meter_line warp)"
  case "$_l" in "warp plan   : 2 Warp (Oz) plan jobs today"*) ok "meter line: '$_l'" ;; *) bad "meter line: '$_l'" ;; esac
  [ -z "$(_lane_plan_meter_line cursor quiet)" ] && ok "meter line: quiet cursor (0 jobs, up) prints nothing" || bad "meter line: quiet cursor printed"
  _lane_down_mark cursor 600 "plan limit exhausted"
  _l="$(_lane_plan_meter_line cursor quiet)"
  case "$_l" in *"cursor lane DOWN (plan limit exhausted)"*) ok "meter line: quiet cursor prints when DOWN, with the reason" ;; *) bad "meter line: down cursor -> '$_l'" ;; esac
  _all="$(_plan_lanes_meter quiet)"
  printf '%s' "$_all" | grep -q '^warp plan' && ok "iterator: warp line present" || bad "iterator: warp line missing"
  printf '%s' "$_all" | grep -q 'cursor lane DOWN' && ok "iterator: cursor down notice present" || bad "iterator: cursor notice missing"
  printf '%s' "$_all" | grep -q '^cline plan' && bad "iterator: idle cline printed" || ok "iterator: idle cline silent"
  _lane_down_clear cursor
else
  ok "meter: jq absent, count assertions skipped"
fi

# === (g) structural: every plan-lane delegate feeds the hook; brief/status use the iterator ========
for l in droid cursor warp cline cx cc; do
  grep -q "_lane_plan_limit_after_run $l " "$SRC" && ok "structure: delegate for $l calls the after-run hook" || bad "structure: $l delegate lacks the hook"
done
[ "$(grep -c '_run_tee_stderr "$_lerr"' "$SRC")" -ge 5 ] && ok "structure: engine + codex delegates capture stderr via _run_tee_stderr" || bad "structure: stderr capture count $(grep -c '_run_tee_stderr "$_lerr"' "$SRC")"
[ "$(grep -c '_plan_lanes_meter' "$SRC")" -ge 3 ] && ok "structure: brief + status call the plan-lanes iterator" || bad "structure: iterator not wired"
grep -q '_lane_plan_key "${1:-}")"' "$SRC" && ok "structure: _lane_free_probe keys on the plan-lane resolver" || bad "structure: probe resolver not generalized"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
