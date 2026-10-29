#!/usr/bin/env bash
# test_failover_pick.sh — CROSS-HARNESS FAILOVER. Fixture/mock driven (fake CLIs on PATH stand
# in for doctor readiness; posture markers stand in for lane-down verdicts; the plan-limit blocks
# write the signal). Pins: (a) _failover_pick picks a READY lane and never a down, absent, source or
# unconsented-cash lane; same model on another harness is preferred, else the nearest tier from the
# tier table (cheaper on a tie), with consent unlocking cash lanes; (b) the plan-limit blocks leave a
# signal only for non-"answered" verdicts; (c) _failover_hop rebuilds argv for the pick and prints the
# human [failover] line; a MUTATING job is re-dispatched FRESH with a handoff note (current repo state,
# never a byte-level resume); a pinned -m is never switched silently; the hop budget stops ping-pong;
# (d) no ready harness -> the honest "every lane you have is at its limit or absent" STOP line naming the
# soonest reset and any cash lane that would need consent; (e) route_delegate wires the hop on BOTH
# dispatch paths.
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
_quota_note_refusal() { :; }
# Readiness stand-ins: a CLI on PATH == "doctor says ready". OpenRouter readiness is keyed on FAKE_OR_KEY
# so no real key file is read.
FB="$TMP/fakebin"; mkdir -p "$FB"
mk() { for c in "$@"; do printf '#!/usr/bin/env bash\necho ok\n' > "$FB/$c"; chmod +x "$FB/$c"; done; hash -r; }
rmc() { for c in "$@"; do rm -f "$FB/$c"; done; hash -r; }   # hash -r: bash caches lookups, a removed fake would still read as present
_fallback_ready_or() { [ -n "${FAKE_OR_KEY:-}" ]; }
# PATH ISOLATION: readiness == "CLI on PATH", so the REAL codex/claude/droid/... installed on the
# developer's machine must be invisible or every "absent lane" assertion is meaningless. Only the
# fixture dir + the system dirs remain; jq (needed by a few helpers) is linked into the fixture dir.
_jq="$(command -v jq 2>/dev/null)"; [ -n "$_jq" ] && ln -sf "$_jq" "$FB/jq"
export PATH="$FB:/usr/bin:/bin:/usr/sbin:/sbin"; hash -r
for c in codex claude droid oz cursor-agent cline agy devin; do command -v "$c" >/dev/null 2>&1 && { echo "FAIL: PATH isolation leaked a real '$c'"; exit 1; }; done

# === (a) _failover_pick ==========================================================================
_lane_down_mark dv 41220 "plan quota exhausted"
mk droid codex
_p="$(_failover_pick dv glm-5.2 run)"; [ "$_p" = "cx|luna|tier:mid" ] && ok "pick: dv down, glm-5.2 (capable), droid+codex ready -> nearest tier, cheaper first: cx luna (mid)" || bad "pick: got '$_p'"
rmc codex
_p="$(_failover_pick dv glm-5.2 run)"; [ "$_p" = "droid||tier:mid" ] && ok "pick: only droid ready -> droid's default model (tier candidate)" || bad "pick: got '$_p'"
mk codex
_p="$(_failover_pick dv kimi-k3 run)"; [ "$_p" = "droid|kimi-k3|same-model" ] && ok "pick: same model wins over tier: kimi-k3 on droid beats cx" || bad "pick: got '$_p'"
_p="$(_failover_pick devin kimi run)"; [ "$_p" = "droid|kimi-k3|same-model" ] && ok "pick: 'devin' token + alias 'kimi' fold correctly" || bad "pick: got '$_p'"
_lane_down_mark cx 300
_p="$(_failover_pick dv glm-5.2 run)"; [ "$_p" = "droid||tier:mid" ] && ok "pick: a DOWN target (cx) is skipped" || bad "pick: down cx picked: '$_p'"
_lane_down_clear cx
_p="$(_failover_pick cx luna run)"; case "$_p" in cx\|*) bad "pick: source lane cx picked back: '$_p'" ;; *) ok "pick: never the source lane (got '${_p:-<empty>}')" ;; esac
mk claude; export FAKE_OR_KEY=1
_p="$(_failover_pick dv glm-5.2 run)"; [ "$_p" = "cc|sonnet|tier:mid" ] && ok "pick: OpenRouter serves glm but is CASH without consent -> skipped; cc sonnet (mid) picked" || bad "pick: got '$_p'"
case " $(_failover_cash_skipped) " in *" or "*) ok "pick: skipped cash lane remembered across the \$(...) (or)" ;; *) bad "pick: cash skip not recorded: '$(_failover_cash_skipped)'" ;; esac
_p="$(OSRC_FAILOVER_CASH_OK=1 _failover_pick dv glm-5.2 run)"; [ "$_p" = "or|glm|same-model" ] && ok "pick: with OSRC_FAILOVER_CASH_OK=1 the same model on OpenRouter is chosen" || bad "pick: got '$_p'"
unset FAKE_OR_KEY; rmc droid codex claude
_p="$(_failover_pick dv glm-5.2 run)"; [ -z "$_p" ] && ok "pick: nothing ready -> empty (no invented capacity)" || bad "pick: invented '$_p'"
mk oz
_p="$(_failover_pick dv glm-5.2 run)"; [ "$_p" = "warp||tier:mid" ] && ok "pick: warp readiness via its cli field (no ready_fn declared)" || bad "pick: got '$_p'"
rmc oz
_lane_down_clear dv

# === (b) the blocks leave a signal ===============================================================
FX="$TMP/fx"; mkdir -p "$FX"
printf "Error: You've hit your usage limit. Try again in 2h 15m.\n" > "$FX/cx-hit"
printf 'Error: Your daily usage quota has been exhausted. It resets in 11h26m.\n' > "$FX/dv-daily"
_failover_signal_clear
_failover_signal_pending && bad "signal: pending with no file" || ok "signal: none pending initially"
_session_limits() { printf 'codex5h=100\n'; }
_lane_plan_limit_block cx "$FX/cx-hit" gpt-5.6 >/dev/null 2>&1
_failover_signal_pending && ok "signal: cx confirmed block -> pending" || bad "signal: cx block left nothing"
[ "$_FO_LANE" = cx ] && [ "$_FO_MODEL" = gpt-5.6 ] && [ "$_FO_VERDICT" = confirmed ] && [ "$_FO_RESET" = 8100 ] && ok "signal: lane/model/verdict/reset carried ($_FO_LANE $_FO_MODEL $_FO_VERDICT $_FO_RESET)" || bad "signal: fields '$_FO_LANE|$_FO_MODEL|$_FO_VERDICT|$_FO_RESET'"
case "$_FO_REASON" in *"plan limit spent"*"2h15m"*) ok "signal: human reason with the lane's reset" ;; *) bad "signal: reason '$_FO_REASON'" ;; esac
_lane_down_clear cx; _failover_signal_clear
_session_limits() { printf 'codex5h=40\n'; }
_lane_plan_limit_block cx "$FX/cx-hit" gpt-5.6 >/dev/null 2>&1
_failover_signal_pending && [ "$_FO_VERDICT" = inconclusive ] && ok "signal: inconclusive verdict is still a failover trigger" || bad "signal: inconclusive -> '$_FO_VERDICT'"
_lane_down_clear cx; _failover_signal_clear
printf '#!/usr/bin/env bash\necho pong\n' > "$FB/devin"; chmod +x "$FB/devin"     # free probe ANSWERS
_devin_plan_quota_block "$FX/dv-daily" claude-opus-5 scope advice >/dev/null 2>&1
_failover_signal_read && [ "$_FO_VERDICT" = answered ] && ok "signal: dv block with an answering probe -> verdict answered" || bad "signal: dv answered -> '$_FO_VERDICT'"
_failover_signal_pending && bad "signal: 'answered' treated as pending" || ok "signal: 'answered' is NOT a failover trigger"
printf '#!/usr/bin/env bash\nprintf "Error: Your daily usage quota has been exhausted. It resets in 11h26m.\\n" >&2; exit 1\n' > "$FB/devin"
_devin_plan_quota_block "$FX/dv-daily" glm-5.2 scope advice >/dev/null 2>&1
_failover_signal_pending && [ "$_FO_LANE" = dv ] && [ "$_FO_VERDICT" = confirmed ] && [ "$_FO_RESET" = 41160 ] && ok "signal: dv confirmed block -> pending with Devin's reset" || bad "signal: dv confirmed -> '$_FO_LANE|$_FO_VERDICT|$_FO_RESET'"
case "$_FO_REASON" in *"daily quota spent"*"no free models there until reset"*) ok "signal: dv reason reads like the spec example" ;; *) bad "signal: dv reason '$_FO_REASON'" ;; esac
rmc devin; _failover_signal_clear; _lane_down_clear dv

# === (c) _failover_hop: argv rebuild + notice + mutating handoff + pin + budget ===================
hop() { # <tier> <verb> [env...]  (runs with route_delegate's locals simulated; prints "rc|ARGV|stderr")
  local tier="$1" verb="$2"; shift 2
  ( RESOLVED_ID="${HOP_MODEL:-luna}"; disp="${HOP_DISP:-cxnative}"; _fb_user_pinned="${HOP_PINNED:-0}"; _fo_hops="${HOP_HOPS:-0}"
    REST=("fix" "the" "tests"); TIER_FLAG=""; EFFORT=""; WITH_SPEC=""; ARGV=(run fix the tests)
    err="$TMP/hop.err"; rc=0
    _failover_hop "$tier" "$verb" 2> "$err" || rc=$?
    printf '%s\n' "$rc"; printf '%s\n' "${#ARGV[@]}"; printf '%s\n' "${ARGV[@]}"; printf -- '--ERR--\n'; cat "$err"; printf '%s\n' "hops=$_fo_hops pinned=${OSRC_FALLBACK_PINNED:-0}" )
}
# C1 read-only hop cx -> droid
mk droid
_failover_signal_write cx luna confirmed "plan limit spent (resets in 2h15m)" 8100
_o="$(hop auto run)"; _rc="$(printf '%s' "$_o" | sed -n 1p)"; _n="$(printf '%s' "$_o" | sed -n 2p)"
[ "$_rc" = 0 ] && ok "hop: read-only cx->droid armed (rc0)" || bad "hop: rc=$_rc"
[ "$(printf '%s' "$_o" | sed -n 3,4p | tr '\n' ' ')" = "--provider droid " ] && [ "$_n" = 5 ] && ok "hop: argv = --provider droid + task (no -m: lane default; no handoff note on read-only)" || bad "hop: argv: $(printf '%s' "$_o" | sed -n 3,7p | tr '\n' ' ')"
printf '%s' "$_o" | grep -q '>>> \[failover\] Codex (ChatGPT plan) plan limit spent (resets in 2h15m). You have Droid (Factory) — moving this to its default model there (its nearest-tier equivalent (mid)) and continuing.' \
  && ok "hop: human notice names source + reason + target + model" || bad "hop: notice: $(printf '%s' "$_o" | grep failover)"
printf '%s' "$_o" | grep -q 'FRESH' && bad "hop: read-only notice mentions FRESH re-dispatch" || ok "hop: read-only notice has no handoff language"
printf '%s' "$_o" | grep -q 'hops=1 pinned=1' && ok "hop: hop counter + hop-mode pin set" || bad "hop: state: $(printf '%s' "$_o" | tail -1)"
_failover_signal_pending && bad "hop: signal not consumed" || ok "hop: signal consumed by the hop"
# C2 mutating hop -> FRESH re-dispatch with handoff note
_failover_signal_write cx luna confirmed "plan limit spent" 8100
_o="$(hop accept-edits edit)"; _rc="$(printf '%s' "$_o" | sed -n 1p)"; _n="$(printf '%s' "$_o" | sed -n 2p)"
[ "$_rc" = 0 ] && [ "$_n" = 6 ] && ok "hop: mutating job re-dispatched with one extra element (the handoff note)" || bad "hop mutating: rc=$_rc n=$_n"
_note="$(printf '%s' "$_o" | sed -n 5p)"
case "$_note" in "[handoff] This task was started on Codex (ChatGPT plan) (luna)"*"git status"*"Do not redo completed steps"*"The original task follows."*) ok "hop: handoff note = continue from the CURRENT repo state" ;; *) bad "hop: note '$_note'" ;; esac
[ "$(printf '%s' "$_o" | sed -n 6,8p | tr '\n' ' ')" = "fix the tests " ] && ok "hop: original task follows the note verbatim" || bad "hop: task tail: $(printf '%s' "$_o" | sed -n 6,8p | tr '\n' ' ')"
printf '%s' "$_o" | grep -q 'continuing FRESH from the current repo state: the new agent reads the half-done files' && ok "hop: mutating notice says FRESH + reads the half-done files" || bad "hop: mutating notice missing"
printf '%s' "$_o" | grep -q 'nothing from the interrupted turn is replayed' && ok "hop: mutating notice rules out replay" || bad "hop: replay wording missing"
printf '%s' "$_o" | grep -qiE -- '--resume|--continue|resume-session' && bad "hop: argv carries a resume flag" || ok "hop: no byte-level resume flag anywhere in the rebuilt argv"
# C3 nothing ready -> STOP line with soonest reset (+ cash hint when a cash lane was skipped)
rmc droid
_lane_down_mark dv 41220 "plan quota exhausted"
_failover_signal_write dv glm-5.2 confirmed "daily quota spent (shared daily plan bucket; no free models there until reset in 11h26m)" 41160
_o="$(HOP_MODEL=glm-5.2 HOP_DISP=devin hop auto run)"; _rc="$(printf '%s' "$_o" | sed -n 1p)"
[ "$_rc" = 1 ] && ok "hop: nothing ready -> rc1 (caller stops)" || bad "hop nothing: rc=$_rc"
printf '%s' "$_o" | grep -q '>>> \[failover\] every lane you have is at its limit or absent; nothing to fail over to (Devin daily quota spent' && printf '%s' "$_o" | grep -q 'Waiting for Devin in 11h' && ok "hop: STOP line = spec wording + reason + soonest reset (Devin in 11h…)" || bad "hop: stop line: $(printf '%s' "$_o" | grep failover)"
printf '%s' "$_o" | grep -q 'or add a lane' && ok "hop: STOP line suggests adding a lane" || bad "hop: add-a-lane missing"
printf '%s' "$_o" | grep -q 'hops=0' && ok "hop: no hop counted on a stop" || bad "hop: counted a hop on stop"
[ "$(printf '%s' "$_o" | sed -n 3p)" = "run" ] && ok "hop: argv untouched on a stop" || bad "hop: argv changed on stop"
mk claude; export FAKE_OR_KEY=1
_failover_signal_write dv glm-5.2 confirmed "daily quota spent" 41160
_o="$(HOP_MODEL=glm-5.2 HOP_DISP=devin hop auto run)"
printf '%s' "$_o" | grep -q 'You have Claude Code (Claude plan) — moving this to sonnet there' && ok "hop: dv->cc sonnet when cc is the only ready plan lane (or is cash)" || bad "hop: $(printf '%s' "$_o" | grep failover)"
rmc claude
_failover_signal_write dv glm-5.2 confirmed "daily quota spent" 41160
_o="$(HOP_MODEL=glm-5.2 HOP_DISP=devin hop auto run)"
printf '%s' "$_o" | grep -q 'nothing to fail over to' && printf '%s' "$_o" | grep -q '(or would take it but spends cash; allow that with OSRC_FAILOVER_CASH_OK=1.)' && ok "hop: only a cash lane left -> STOP line names it + the consent switch, never uses it" || bad "hop: cash hint: $(printf '%s' "$_o" | grep failover)"
unset FAKE_OR_KEY; _lane_down_clear dv
# C4 budget
mk droid
_failover_signal_write cx luna confirmed "plan limit spent" 8100
_o="$(HOP_HOPS=2 hop auto run)"; [ "$(printf '%s' "$_o" | sed -n 1p)" = 1 ] && printf '%s' "$_o" | grep -q 'already hopped 2 time(s) (OSRC_FAILOVER_MAX=2)' && ok "hop: budget exhausted -> stops instead of ping-pong" || bad "hop budget: $(printf '%s' "$_o" | grep failover)"
_failover_signal_write cx luna confirmed "plan limit spent" 8100
_o="$(OSRC_FAILOVER_MAX=3 HOP_HOPS=2 hop auto run)"; [ "$(printf '%s' "$_o" | sed -n 1p)" = 0 ] && ok "hop: OSRC_FAILOVER_MAX raises the budget" || bad "hop: budget override ignored"
# C5 pinned -m
_failover_signal_write cx luna confirmed "plan limit spent" 8100
_o="$(HOP_PINNED=1 hop auto run)"; [ "$(printf '%s' "$_o" | sed -n 1p)" = 1 ] && printf '%s' "$_o" | grep -q 'pinned choice, so I will not switch models silently' && ok "hop: pinned -m + different-model pick -> refused loudly" || bad "hop pin: $(printf '%s' "$_o" | grep failover)"
_failover_signal_write cx luna confirmed "plan limit spent" 8100
_o="$(OSRC_FALLBACK_PINNED=1 HOP_PINNED=1 hop auto run)"; [ "$(printf '%s' "$_o" | sed -n 1p)" = 0 ] && ok "hop: OSRC_FALLBACK_PINNED=1 allows the switch" || bad "hop: pinned override ignored"
_failover_signal_write dv kimi-k3 confirmed "daily quota spent" 41160
_o="$(HOP_MODEL=kimi-k3 HOP_DISP=devin HOP_PINNED=1 hop auto run)"; [ "$(printf '%s' "$_o" | sed -n 1p)" = 0 ] && printf '%s' "$_o" | grep -q 'moving this to kimi-k3 there (the same model)' && ok "hop: pinned -m + SAME model on droid -> allowed (the pin's intent is honored)" || bad "hop same-model pin: $(printf '%s' "$_o" | grep failover)"
# C6 answered verdict -> not a hop
_failover_signal_write cx luna answered "still answers" ""
_o="$(hop auto run)"; [ "$(printf '%s' "$_o" | sed -n 1p)" = 1 ] && ok "hop: 'answered' verdict -> rc1, no hop" || bad "hop: answered verdict hopped"
rmc droid

# === (e) structural: both dispatch paths wire the hop; the loop owns the hop counter ==============
[ "$(grep -c '_failover_hop "$tier" "$verb"' "$SRC")" = 2 ] && ok "structure: route_delegate calls _failover_hop on both dispatch paths" || bad "structure: hop call count $(grep -c '_failover_hop "$tier" "$verb"' "$SRC")"
[ "$(grep -cE '^ +_failover_signal_clear$' "$SRC")" -ge 2 ] && ok "structure: signal cleared before each dispatch" || bad "structure: signal clear count"
grep -q 'local _fo_hops=0' "$SRC" && ok "structure: hop counter initialized per route_delegate call" || bad "structure: hop counter missing"
grep -qiE 'resume|continue-session' <<<"$(awk '/^_failover_rebuild_argv\(\)/,/^}/' "$SRC")" && bad "structure: rebuild references a resume" || ok "structure: rebuild has no resume path"
grep -q '_failover_pick "$src"' <<<"$(awk '/^_failover_hop\(\)/,/^}/' "$SRC")" && ok "structure: hop delegates the choice to _failover_pick" || bad "structure: hop bypasses the picker"
grep -q '_failover_signal_write dv "$model" confirmed' "$SRC" && grep -q '_failover_signal_write "$lane" "$model" confirmed' "$SRC" && ok "structure: both blocks signal a confirmed limit" || bad "structure: a block does not signal"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
