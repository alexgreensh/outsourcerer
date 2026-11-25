#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_spend_attack.sh — attack the spend gate on every launch path; assert on what LAUNCHED.
#
# Stub CLIs record their exact argv (and, for interactive sessions, the keystrokes the TUI
# received). A case passes only when the recorded argv shows no paid model started without
# consent, or shows exactly the id the gate judged. Messages are checked only as a second look.
# Holes this suite found (all failed on 2f7d58b): offline case/dot spellings judged as the Free
# id but launched verbatim; `session start` / `continue` with no -m launching an EMPTY --model
# after the gate judged the Free default; `session control relaunch`, `session effort` and
# `session model NAME` starting or switching to a paid model with no consent.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
for _v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL OPENAI_API_KEY OPENAI_BASE_URL \
          CODEX_API_KEY CODEX_HOME CLAUDE_CONFIG_DIR OPENROUTER_API_KEY GEMINI_API_KEY GOOGLE_API_KEY \
          OSRC_SPEND_OK OSRC_SPEND_GATE OSRC_JOB_DIR OSRC_JOB_TOKEN; do unset "$_v"; done

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR%/}/osrc-spendatk.XXXXXX")"
tkill() { TMUX_TMPDIR="$TMP" tmux kill-server >/dev/null 2>&1; }
trap 'tkill; rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
DOH="$TMP/osrc"; OFF="$TMP/osrc-off"; DBIN="$TMP/bin"; LOG="$TMP/argv.log"
for d in "$DOH" "$OFF"; do
  mkdir -p "$d/catalogs" "$d/disk-policy"
  printf 'OSRC_DISK_MIN_GB=0\nOSRC_DISK_PAUSE_GB=0\n' > "$d/disk-policy/settings"
done
mkdir -p "$DBIN"
# devin: headless (-p / -c) runs log argv and exit; an interactive session logs argv, then logs
# every line the TUI receives (the model picker's search text arrives here).
cat > "$DBIN/devin" <<'EOF'
#!/usr/bin/env bash
echo "devin $*" >> "${STUB_LOG:-/dev/null}"
case "${1:-}" in
  auth)   echo "Logged in as stub@example.com"; exit 0 ;;
  models) cat "${DEVIN_STUB_CATALOG:-/dev/null}"; exit 0 ;;
  --help) echo "  --model <MODEL>"; exit 0 ;;
esac
case " $* " in *" -p "*|*" -c "*) exit 0 ;; esac
echo "Devin ready >"
while IFS= read -r l; do echo "tui-input $l" >> "${STUB_LOG:-/dev/null}"; done
exec sleep 60
EOF
# claude: not logged in (billing unprovable = unknown); any launch is logged.
cat > "$DBIN/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >> "${STUB_LOG:-/dev/null}"
case "${1:-}" in auth) echo '{"loggedIn":false}'; exit 1 ;; esac
exit 0
EOF
chmod +x "$DBIN/devin" "$DBIN/claude"
# Catalog: swe-1.7 has ONE Free variant; every other variant is paid in a different malformed way.
# swe-2-1 is newer, has a PAID -high (Fusion text says Free) and a Free -max, so `-m swe` resolves
# to the paid swe-2-1-high.
cat > "$DOH/catalogs/dv.raw.json" <<'EOF'
{"families":[
 {"family_uid":"swe-1.7","aliases":[],"variants":[
   {"model_uid":"swe-1-7-high","cost_tier":"Free"},
   {"model_uid":"swe-1-7-max","cost_tier":"High cost","cost_summary":"Free"},
   {"model_uid":"swe-1-7-xhigh","cost_tier":["Free"],"cost_summary":"Free"},
   {"model_uid":"swe-1-7-low","cost_tier":{"tier":"Free"}},
   {"model_uid":"swe-1-7-medium","cost_summary":"Free for now"},
   {"model_uid":"swe-1-7-none","cost_tier":null,"cost_summary":"Sidekick: Free"},
   {"model_uid":"swe-1-7-promo","cost_tier":1,"cost_summary":"promo: free this week"}]},
 {"family_uid":"swe-2-1","aliases":["swe"],"variants":[
   {"model_uid":"swe-2-1-high","cost_tier":"High cost","cost_summary":"$8/MTok · Sidekick: Free"},
   {"model_uid":"swe-2-1-max","cost_tier":"Free"}]}]}
EOF
printf '["swe-1.7","swe-1-7-high","swe-1-7-max","swe-1-7-xhigh","swe-1-7-low","swe-1-7-medium","swe-1-7-none","swe-1-7-promo","swe-2-1","swe-2-1-high","swe-2-1-max","swe"]\n' \
  > "$DOH/catalogs/dv.json"

engine() {  # real engine against the stubs, non-interactive (stdin /dev/null); HOME_DIR picks OSRC_HOME
  ( cd "$TMP" && STUB_LOG="$LOG" DEVIN_STUB_CATALOG="${CAT-$DOH/catalogs/dv.raw.json}" \
      PATH="$DBIN:$PATH" HOME="$HOME" OSRC_HOME="${HOME_DIR:-$DOH}" OSRC_SOURCED= OSRC_CATALOG_TTL=999999 \
      OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 OSRC_PROVIDER=devin OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 \
      TMUX= TMUX_TMPDIR="$TMP" bash "$SRC" "$@" 2>&1 </dev/null )
}
offline() { CAT=/dev/null HOME_DIR="$OFF" engine "$@"; }
inproc() {  # source the engine and run a snippet (functions in-process)
  ( cd "$TMP" && STUB_LOG="$LOG" DEVIN_STUB_CATALOG="$DOH/catalogs/dv.raw.json" PATH="$DBIN:$PATH" HOME="$HOME" \
      OSRC_HOME="$DOH" OSRC_SOURCED=1 OSRC_CATALOG_TTL=999999 OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 SRC="$SRC" \
      bash -c '. "$SRC" >/dev/null 2>&1; '"$1" 2>&1 </dev/null )
}
# headless launches recorded by the stub: the --model value of each `-p` / `-c` run
launched_ids() { grep -E -- ' -p( |$)| -c ' "$LOG" 2>/dev/null | sed -nE 's/.*--model ([^ ]*).*/\1/p'; }
launched() { launched_ids | grep -qxF -- "$1"; }
nolaunch() { [ -z "$(grep -E -- ' -p( |$)| -c |--respect-workspace-trust' "$LOG" 2>/dev/null | grep -vF -- '--model __list__')" ]; }
wait_log() { local i=0; while [ "$i" -lt 40 ]; do grep -qE -- "$1" "$LOG" 2>/dev/null && return 0; sleep 0.25; i=$((i+1)); done; return 1; }
refuses_paid() {  # <label> <output> <rc> <id>: nothing launched, rc!=0, refusal names the id
  local label="$1" out="$2" rc="$3" id="$4"
  if ! nolaunch; then bad "$label: launched with no consent: $(head -2 "$LOG")"; return; fi
  case "$out" in *"paid-lane:"*"$id"*) [ "$rc" -ne 0 ] && ok "$label" || bad "$label: refusal printed but rc=0" ;;
    *) bad "$label: no launch but no refusal naming $id (rc=$rc): $(printf '%s' "$out" | grep -E 'ERROR|paid' | head -2)" ;; esac
}

# ---- 1. cost_summary says Free, cost_tier is not exactly "Free" -> paid ----------------------
# ---- 4. paid siblings (-max/-xhigh) of the Free -high -> paid --------------------------------
# ---- 5. non-string / missing / null / numeric cost_tier -> paid, no crash --------------------
for m in swe-1-7-max swe-1-7-xhigh swe-1-7-low swe-1-7-medium swe-1-7-none swe-1-7-promo swe-2-1-high; do
  : > "$LOG"; out="$(engine run -m "$m" "say hi")"; rc=$?
  case "$out" in *"jq: error"*|*"unbound variable"*|*"syntax error"*) bad "tier:$m crashed: $(printf '%s' "$out" | grep -m1 -E 'jq|unbound|syntax')"; continue ;; esac
  refuses_paid "tier:$m is paid and refused" "$out" "$rc" "$m"
done
: > "$LOG"; out="$(engine run -m swe-1-7-high "say hi")"; rc=$?
launched swe-1-7-high && [ "$rc" -eq 0 ] && ok "tier: the exact Free swe-1-7-high still runs without asking" \
  || bad "tier: Free swe-1-7-high blocked (rc=$rc): $(printf '%s' "$out" | tail -2)"

# ---- 2. case / dot spellings: the id that launches is the id that was judged ----------------
# Live catalog: the resolver maps any spelling to the catalog's exact uid, which is what is judged.
for m in SWE-1.7-HIGH swe-1.7-high Swe-1-7-High; do
  : > "$LOG"; out="$(engine run -m "$m" "say hi")"; rc=$?
  ids="$(launched_ids | tr '\n' ' ')"
  [ "$ids" = "swe-1-7-high " ] && [ "$rc" -eq 0 ] && ok "spell:$m launched exactly the judged Free id swe-1-7-high" \
    || bad "spell:$m launched '$ids' (rc=$rc)"
done
# Offline: nothing maps the spelling, so the CLI gets it verbatim; it must be judged verbatim too.
for m in SWE-2-HIGH swe.2.high Swe-2-High; do
  : > "$LOG"; out="$(offline run -m "$m" "say hi")"; rc=$?
  refuses_paid "spell:offline $m (launches verbatim) is not judged as swe-2-high" "$out" "$rc" "$m"
  : > "$LOG"; out="$(offline run --spend-ok -m "$m" "say hi")"; rc=$?
  [ "$(launched_ids | tr '\n' ' ')" = "$m " ] && ok "spell:offline consent to $m launches exactly $m" \
    || bad "spell:offline consented $m launched '$(launched_ids | tr '\n' ' ')' (rc=$rc)"
done
: > "$LOG"; out="$(offline run -m swe-2-high "say hi")"; rc=$?
launched swe-2-high && [ "$rc" -eq 0 ] && ok "spell:offline exact swe-2-high still Free" \
  || bad "spell:offline swe-2-high blocked (rc=$rc): $(printf '%s' "$out" | tail -2)"
b="$(inproc 'osrc_lane_billing dv SWE-1.7-HIGH devin')"
[ "$b" = metered ] && ok "spell:billing judges SWE-1.7-HIGH as spelled (not the Free uid)" || bad "spell:billing SWE-1.7-HIGH = '$b'"

# ---- 3. an alias resolving to a paid id, on every launch path --------------------------------
: > "$LOG"; out="$(engine run -m swe "say hi")"; rc=$?
refuses_paid "alias:run -m swe refuses the paid swe-2-1-high it would launch" "$out" "$rc" swe-2-1-high
: > "$LOG"; out="$(engine bg -m swe "say hi")"; rc=$?; sleep 2
refuses_paid "alias:bg -m swe refuses swe-2-1-high" "$out" "$rc" swe-2-1-high
: > "$LOG"; out="$(engine fanout -m swe -- "task a" "task b")"; rc=$?
i=0; while [ "$i" -lt 60 ] && [ "$(grep -lsF 'paid-lane:' "$DOH"/jobs/*/*.log 2>/dev/null | wc -l)" -lt 2 ]; do sleep 0.5; i=$((i+1)); done
if launched swe-2-1-high; then bad "alias:fanout -m swe launched paid swe-2-1-high with no consent"
else out="$out $(cat "$DOH"/jobs/*/*.log 2>/dev/null)"   # fanout members refuse inside their job
  case "$out" in *"paid-lane:"*swe-2-1-high*) ok "alias:fanout -m swe launched nothing paid; each member refused swe-2-1-high" ;;
  *) bad "alias:fanout -m swe: no paid-lane refusal (rc=$rc): $(printf '%s' "$out" | grep -E 'ERROR|paid' | head -2)" ;; esac; fi
: > "$LOG"; out="$(engine continue -m swe "follow up")"; rc=$?
refuses_paid "alias:continue -m swe refuses swe-2-1-high" "$out" "$rc" swe-2-1-high
: > "$LOG"; out="$(engine session start -m swe)"; rc=$?
refuses_paid "alias:session start -m swe refuses swe-2-1-high" "$out" "$rc" swe-2-1-high
tkill
: > "$LOG"; out="$(engine --spend-ok run -m swe "say hi")"; rc=$?
[ "$(launched_ids | tr '\n' ' ')" = "swe-2-1-high " ] && ok "alias:consent to -m swe launches exactly the gated swe-2-1-high" \
  || bad "alias:consented -m swe launched '$(launched_ids | tr '\n' ' ')' (rc=$rc)"

# ---- no -m: the launch must carry the id the gate judged (never an empty --model) -----------
: > "$LOG"; out="$(engine continue "follow up")"; rc=$?
ids="$(launched_ids | tr '\n' ' ')"
case "$ids" in
  "swe-1-7-high "|"swe-2-1-max ") ok "default:bare continue launches the judged Free default ($ids)" ;;
  *) bad "default:bare continue launched --model '$ids' (rc=$rc; empty = Devin picks, unjudged)" ;;
esac
: > "$LOG"; out="$(engine session start)"; rc=$?
wait_log 'respect-workspace-trust' || true
sm="$(grep -E -- '--respect-workspace-trust' "$LOG" | sed -nE "s/.*--model ([^ ]*) .*/\1/p" | head -1)"
case "$sm" in
  swe-1-7-high|swe-2-1-max) ok "default:bare session start launches the judged Free default ($sm)" ;;
  *) bad "default:bare session start launched --model '$sm' (rc=$rc)" ;;
esac
tkill
b="$(inproc 'OSRC_SPEND_NEXT=x _osrc_spend_gate dv "" devin probe && echo PASSED')"
case "$b" in *PASSED*) bad "default:gate passed a Devin launch whose model it was not told" ;;
  *"spend gate"*) ok "default:gate asks when a Devin caller names no model" ;; *) bad "default:gate dv '' said: $b" ;; esac

# ---- 6. an old-format cache listing a paid id as Free is ignored ------------------------------
mt="$(stat -c %Y "$DOH/catalogs/dv.raw.json" 2>/dev/null || stat -f %m "$DOH/catalogs/dv.raw.json")"
for row in "v1|$mt|swe-2-1-high swe-1-7-max" "$mt|swe-2-1-high swe-1-7-max" "v2|0|swe-2-1-high swe-1-7-max" "v2|$((mt+1))|swe-2-1-high swe-1-7-max"; do
  printf '%s\n' "$row" > "$DOH/.devin-free-ids"
  : > "$LOG"; out="$(engine run -m swe-2-1-high "say hi")"; rc=$?
  refuses_paid "cache:'${row%%|*}|…' row naming swe-2-1-high Free is ignored" "$out" "$rc" swe-2-1-high
done
rm -f "$DOH/.devin-free-ids"

# ---- 7. unknown billing, no catalog, non-interactive, no --spend-ok -> refuse, nothing runs ---
for m in glm-5.2 swe-2-max swe-2 swe-2-1-high; do
  : > "$LOG"; out="$(offline run -m "$m" "say hi")"; rc=$?
  if nolaunch && [ "$rc" -ne 0 ]; then ok "unknown:offline $m refused, nothing launched"
  else bad "unknown:offline $m rc=$rc launched: $(head -2 "$LOG")"; fi
done
: > "$LOG"; out="$(offline --provider claude run -m sonnet "say hi")"; rc=$?
if grep -qE '^claude .*(-p|--print)' "$LOG" || ! [ "$rc" -ne 0 ]; then bad "unknown:claude with no provable login launched (rc=$rc): $(grep '^claude' "$LOG" | head -2)"
else ok "unknown:claude with no provable login refused, nothing launched"; fi
: > "$LOG"; out="$(offline session start -m swe-2-max)"; rc=$?
refuses_paid "unknown:offline session start swe-2-max refused" "$out" "$rc" swe-2-max
tkill

# ---- 8. --spend-ok covers exactly one command; nothing makes it stick -------------------------
: > "$LOG"; out="$(engine run --spend-ok -m swe-1-7-max "say hi")"; rc=$?
launched swe-1-7-max && ok "once:--spend-ok launches swe-1-7-max for this command" || bad "once:consented run did not launch (rc=$rc)"
: > "$LOG"; out="$(engine run -m swe-1-7-max "say hi")"; rc=$?
refuses_paid "once:the next command asks again" "$out" "$rc" swe-1-7-max
if grep -rlsF -- 'spend-ok' "$DOH" --include='*settings*' --include='*consent*' --include='*.env' >/dev/null 2>&1; then
  bad "once:a consent file was persisted: $(grep -rlsF -- 'spend-ok' "$DOH" | head -2)"; else ok "once:no consent persisted to a settings/consent file"; fi
for envset in "OSRC_SPEND_OK=1" "OSRC_SPEND_GATE=0" "_OSRC_SPEND_BOUND_LANE=dv _OSRC_SPEND_BOUND_MODEL=swe-1-7-max OSRC_SPEND_OK=1" \
              "OSRC_FAILOVER_CASH_OK=1" "OSRC_PREFLIGHT_PAIR=dv|swe-1-7-max _OSRC_PREFLIGHT_PAIR=dv|swe-1-7-max"; do
  : > "$LOG"; out="$(export $envset; engine run -m swe-1-7-max "say hi")"; rc=$?
  refuses_paid "once:env $envset grants nothing" "$out" "$rc" swe-1-7-max
done
# The bg job marker: a wrong token, or a job dir outside $OSRC_HOME/jobs, grants nothing.
mkdir -p "$DOH/jobs/j1" "$TMP/elsewhere"
printf '#osrc-spend-ok token=t0k\ndv|swe-1-7-max\n' > "$DOH/jobs/j1/.spend-ok"
cp "$DOH/jobs/j1/.spend-ok" "$TMP/elsewhere/.spend-ok"
: > "$LOG"; out="$(export OSRC_JOB_DIR="$DOH/jobs/j1" OSRC_JOB_TOKEN=wrong; engine run -m swe-1-7-max "say hi")"; rc=$?
refuses_paid "once:a job marker with another job's token grants nothing" "$out" "$rc" swe-1-7-max
: > "$LOG"; out="$(export OSRC_JOB_DIR="$TMP/elsewhere" OSRC_JOB_TOKEN=t0k; engine run -m swe-1-7-max "say hi")"; rc=$?
refuses_paid "once:a marker outside the jobs dir grants nothing" "$out" "$rc" swe-1-7-max
# The right token (the bg child's own secret) consents ONCE: the marker is consumed.
: > "$LOG"; out="$(export OSRC_JOB_DIR="$DOH/jobs/j1" OSRC_JOB_TOKEN=t0k; engine run -m swe-1-7-max "say hi")"; rc=$?
launched swe-1-7-max && ok "once:the job's own marker consents its one bound launch" || bad "once:job marker launch failed (rc=$rc)"
: > "$LOG"; out="$(export OSRC_JOB_DIR="$DOH/jobs/j1" OSRC_JOB_TOKEN=t0k; engine run -m swe-1-7-max "say hi")"; rc=$?
refuses_paid "once:the consumed job marker does not consent a second launch" "$out" "$rc" swe-1-7-max

# ---- 9. hops, self-heal and relaunches onto a paid model ask or refuse -----------------------
# Consent bound to one paid pair does not cover a hop to another paid model.
b="$(inproc 'OSRC_SPEND_OK=1; OSRC_SPEND_NEXT=x; _osrc_spend_gate dv swe-1-7-max devin first >/dev/null 2>&1 && echo FIRST; _osrc_spend_gate dv swe-2-1-high devin hop && echo HOPPED')"
case "$b" in FIRST*"spend gate"*) ok "hop:consent for swe-1-7-max does not cover a hop to swe-2-1-high" ;; *) bad "hop:bound consent result: $(printf '%s' "$b" | tail -2)" ;; esac
b="$(inproc '_osrc_lane_spendable dv swe-2-1-high && echo SPENDABLE || echo NO')"
[ "$b" = NO ] && ok "hop:fallback pickers never treat a paid Devin model as spendable" || bad "hop:_osrc_lane_spendable dv swe-2-1-high = $b"
# cc -> Devin self-heal (a direct delegate() call) with consent bound to the OpenRouter pair.
: > "$LOG"
out="$(inproc 'OSRC_SPEND_OK=1; _OSRC_SPEND_BOUND_LANE=or; _OSRC_SPEND_BOUND_MODEL=z-ai/glm-5.2; tier=auto; PROVIDER=devin delegate auto "" -m swe "heal"')"
if launched swe-2-1-high; then bad "hop:cc->Devin self-heal launched paid swe-2-1-high on OpenRouter consent"
else case "$out" in *"spend gate"*) ok "hop:cc->Devin self-heal onto paid swe-2-1-high refused" ;; *) bad "hop:self-heal no refusal: $(printf '%s' "$out" | tail -2)" ;; esac; fi
# session effort relaunches the pane process (codex/cc/droid): a new process asks like a start.
b="$(inproc '_session_control_relaunch() { echo RELAUNCHED >&2; }; SESSION_NAME=s1; OSRC_SPEND_NEXT=x; _session_relaunch_effort codex sol high')"
case "$b" in *RELAUNCHED*) bad "relaunch:session effort relaunched codex (billing unproven) with no consent" ;;
  *"spend gate"*) ok "relaunch:session effort relaunch on an unproven-billing lane asks first" ;; *) bad "relaunch:effort said: $(printf '%s' "$b" | tail -2)" ;; esac
# session control relaunch / session model: a NEW process or a model switch is a new spend.
: > "$LOG"; out="$(engine --spend-ok session start -m swe-1-7-max)"; rc=$?
if wait_log 'swe-1-7-max --respect' && [ "$rc" -eq 0 ]; then
  sleep 1; : > "$LOG"
  out="$(engine session model swe-2-1-high)"; rc=$?
  sleep 2
  if grep -q 'tui-input.*swe-2-1-high' "$LOG"; then bad "model:session model typed paid swe-2-1-high into the picker with no consent"
  else case "$out" in *"paid-lane:"*swe-2-1-high*) ok "model:session model swe-2-1-high asks first" ;;
    *) bad "model:no switch but no refusal (rc=$rc): $(printf '%s' "$out" | tail -2)" ;; esac; fi
  : > "$LOG"; out="$(engine session model swe-1-7-high)"; rc=$?
  wait_log 'tui-input.*swe-1-7-high' && ok "model:switch to the exact Free swe-1-7-high needs no consent" \
    || bad "model:Free switch blocked (rc=$rc): $(printf '%s' "$out" | tail -2)"
  : > "$LOG"; out="$(engine session model)"; rc=$?
  sleep 2
  if grep -q 'tui-input' "$LOG"; then bad "model:bare session model drove the picker with no consent (choice unknown)"
  else case "$out" in *"spend gate"*) ok "model:bare session model (unknown pick) asks first" ;;
    *) bad "model:bare no refusal (rc=$rc): $(printf '%s' "$out" | tail -2)" ;; esac; fi
  sleep 1; : > "$LOG"
  out="$(engine session control relaunch)"; rc=$?
  sleep 1
  if grep -q -- '--model swe-1-7-max' "$LOG"; then bad "relaunch:control relaunch restarted paid swe-1-7-max with no consent"
  else case "$out" in *"paid-lane:"*swe-1-7-max*) ok "relaunch:control relaunch of a paid session asks again" ;;
    *) bad "relaunch:no relaunch but no refusal (rc=$rc): $(printf '%s' "$out" | tail -2)" ;; esac; fi
  : > "$LOG"; out="$(engine --spend-ok session control relaunch)"; rc=$?
  # (the stub cannot pass the relaunch lifecycle checks, so only the recorded argv is asserted)
  wait_log 'swe-1-7-max --respect' && ok "relaunch:--spend-ok relaunches exactly swe-1-7-max" \
    || bad "relaunch:consented relaunch did not launch swe-1-7-max (rc=$rc): $(printf '%s' "$out" | tail -2)"
else
  bad "relaunch:setup: consented session start did not launch swe-1-7-max (rc=$rc): $(printf '%s' "$out" | grep -E 'ERROR' | head -2)"
fi
tkill

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
