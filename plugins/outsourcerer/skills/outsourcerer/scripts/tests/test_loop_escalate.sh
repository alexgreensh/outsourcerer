#!/usr/bin/env bash
# test_loop_escalate.sh — the built-in `loop escalate` primitive: the cheap->expensive bounded
# loop. The cheapest ladder rung runs first; a pricier rung is delegated ONLY after the external
# --check fails below (per-tier budget spent, or the identical failure twice = that model is
# stuck). Ends in success/blocked/max_turns/max_time like every loop, with per-tier receipts that
# make the saving visible: a cheap pass never touches the expensive model.
# The delegate is mocked (SCRIPT_PATH override) so no real cloud call is made.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

# Source the script with the main dispatcher stripped, so cmd_loop/_escalate_ladder/die are defined.
sed '/^[[:space:]]*main "\$@"[[:space:]]*$/d' "$SRC" > "$TMP/src.sh"
set +e; . "$TMP/src.sh" >/dev/null 2>&1; set +e

# Mock delegate: records the -m model it was called with (one per line) and bumps a counter, so
# tests can prove WHICH tier ran. Captures the foreground contract; optionally emits BLOCKED or
# sleeps (for the time-guard test).
MOCK="$TMP/mock.sh"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
m=""; p=""
for a in "$@"; do [ "$p" = "-m" ] && m="$a"; p="$a"; done
echo "$m" >> "$MOCK_MODELS"
echo "run" >> "$MOCK_CNT"
[ -n "${ENVCAP:-}" ] && echo "${OSRC_NO_AUTODETACH:-unset}" >> "$ENVCAP"
[ -n "${MOCK_BLOCK:-}" ] && echo "OSRC::BLOCKED need a human decision"
[ -n "${MOCK_SLEEP:-}" ] && sleep "$MOCK_SLEEP"
exit 0
EOF
chmod +x "$MOCK"
SCRIPT_PATH="$MOCK"   # cmd_loop_escalate delegates via "$SCRIPT_PATH"

# 1. --check is mandatory (the check is the only thing that makes the cheap rung safe to trust).
( cmd_loop escalate "do a thing" >/dev/null 2>&1 ); [ $? -ne 0 ] && ok "loop escalate requires --check (external verification mandatory)" || bad "missing --check did not error"

# 2. a task is mandatory.
( cmd_loop escalate --check "true" >/dev/null 2>&1 ); [ $? -ne 0 ] && ok "loop escalate requires a task" || bad "missing task did not error"

# 3. The WHOLE ladder is validated before anything runs: an unknown rung is a fatal error up
#    front, never a mid-loop surprise after the cheap rungs already spent.
export MOCK_MODELS="$TMP/m_val"; export MOCK_CNT="$TMP/c_val"; rm -f "$MOCK_MODELS"
e="$( ( cmd_loop escalate --ladder "glm-5.2,nope-9x" --check "true" "t" ) 2>&1 )"
[ $? -ne 0 ] && [ ! -f "$MOCK_MODELS" ] && printf '%s' "$e" | grep -q 'nope-9x' \
  && ok "an unknown ladder rung dies BEFORE any delegation, naming the rung" \
  || bad "unknown rung was not caught up front (delegated: $(cat "$MOCK_MODELS" 2>/dev/null | tr '\n' ' '))"

# 4. A one-rung ladder is not an escalation loop; five rungs is a spend plan.
( cmd_loop escalate --ladder "glm-5.2" --check "true" "t" >/dev/null 2>&1 ); [ $? -ne 0 ] \
  && ok "a single-rung ladder is refused (use loop verify for one model)" || bad "single-rung ladder accepted"
( cmd_loop escalate --ladder "haiku,sonnet,glm-5.2,gpt-5.5,fable" --check "true" "t" >/dev/null 2>&1 ); [ $? -ne 0 ] \
  && ok "a five-rung ladder is refused (a spend plan, not a ladder)" || bad "five-rung ladder accepted"

# 5. __escalate-ladder hook: resolves + validates a ladder without delegating, cheapest first,
#    with the table's lane and tier attached.
out="$("$SRC" __escalate-ladder "haiku,glm-5.2,fable" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c .)" -eq 3 ] \
  && [ "$(printf '%s\n' "$out" | sed -n '1p' | cut -f2,5)" = "haiku	budget" ] \
  && [ "$(printf '%s\n' "$out" | sed -n '2p' | cut -f2,5)" = "glm-5.2	capable" ] \
  && [ "$(printf '%s\n' "$out" | sed -n '3p' | cut -f2,5)" = "fable	frontier" ] \
  && ok "__escalate-ladder resolves the ladder cheapest-first with tier labels" \
  || bad "__escalate-ladder output wrong (rc=$rc): $(printf '%s' "$out" | tr '\n' '|')"
"$SRC" __escalate-ladder "glm-5.2,nope-9x" >/dev/null 2>&1; [ $? -ne 0 ] \
  && ok "__escalate-ladder exits non-zero on an unknown rung" || bad "__escalate-ladder accepted an unknown rung"

# 6. THE SAVING (acceptance): a task whose check the cheap model passes never touches the
#    expensive model — the receipt shows only the cheap tier.
export MOCK_MODELS="$TMP/m_cheap"; export MOCK_CNT="$TMP/c_cheap"; : > "$MOCK_MODELS"; : > "$MOCK_CNT"
s="$(cmd_loop escalate --ladder "glm-5.2,fable" --check "true" --max 4 "make it pass" 2>"$TMP/err_cheap")"; rc=$?
[ "$s" = success ] && [ "$rc" -eq 0 ] && ok "cheap rung passes -> state=success, exit 0" || bad "cheap-pass path wrong (state=$s rc=$rc)"
[ "$(grep -c . "$MOCK_MODELS")" -eq 1 ] && [ "$(head -1 "$MOCK_MODELS")" = "glm-5.2" ] \
  && ok "cheap pass delegated exactly once, on the cheap model only" \
  || bad "cheap pass delegated the wrong models: $(tr '\n' ' ' < "$MOCK_MODELS")"
_ld="$(ls -dt "$OSRC_HOME/loops"/*/ 2>/dev/null | head -1)"
{ [ "$(grep -c . "$_ld/receipts.tsv")" -eq 1 ] && ! grep -q 'fable' "$_ld/receipts.tsv"; } \
  && ok "the cost receipt shows ONLY the cheap tier (the expensive model never ran)" \
  || bad "receipt does not prove the cheap-only path: $(cat "$_ld/receipts.tsv" 2>/dev/null | tr '\n' '|')"
grep -q 'never ran' "$TMP/err_cheap" \
  && ok "the saving is narrated, not silent (a non-event made visible)" \
  || bad "cheap-pass run did not report that the pricier rungs never ran"

# 7. ESCALATION (acceptance): a task the cheap model fails climbs the ladder, and the receipt
#    shows both tiers. Stub check: passes only once the top rung has been delegated.
export MOCK_MODELS="$TMP/m_esc"; export MOCK_CNT="$TMP/c_esc"; : > "$MOCK_MODELS"; : > "$MOCK_CNT"
s="$(cmd_loop escalate --ladder "glm-5.2,fable" --per-tier 1 --max 6 \
      --check 'grep -qx fable "$MOCK_MODELS"' "task" 2>"$TMP/err_esc")"; rc=$?
[ "$s" = success ] && [ "$rc" -eq 0 ] && ok "cheap fails, top rung passes -> state=success, exit 0" || bad "escalation path wrong (state=$s rc=$rc)"
[ "$(sed -n '1p' "$MOCK_MODELS")" = "glm-5.2" ] && [ "$(sed -n '2p' "$MOCK_MODELS")" = "fable" ] && [ "$(grep -c . "$MOCK_MODELS")" -eq 2 ] \
  && ok "the cheap rung failed first, THEN the expensive rung was delegated (in order)" \
  || bad "escalation order wrong: $(tr '\n' ' ' < "$MOCK_MODELS")"
_ld="$(ls -dt "$OSRC_HOME/loops"/*/ 2>/dev/null | head -1)"
awk -F'\t' '$2==1 && $6=="fail" {f=1} $2==2 && $6=="pass" {p=1} END{exit !(f&&p)}' "$_ld/receipts.tsv" \
  && ok "the receipt shows BOTH tiers: tier 1 fail, tier 2 pass" \
  || bad "receipts do not show both tiers: $(cat "$_ld/receipts.tsv" 2>/dev/null | tr '\n' '|')"
grep -q 'escalating to tier 2' "$TMP/err_esc" \
  && ok "the escalation itself is announced (which tier, why)" || bad "escalation happened silently"

# 8. LADDER EXHAUSTED -> blocked: every rung failed the check, so a human hears about it.
export MOCK_MODELS="$TMP/m_xh"; export MOCK_CNT="$TMP/c_xh"; : > "$MOCK_MODELS"; : > "$MOCK_CNT"
s="$(cmd_loop escalate --ladder "glm-5.2,fable" --per-tier 1 --max 6 --check "false" "task" 2>/dev/null)"; rc=$?
[ "$s" = blocked ] && [ "$rc" -eq 3 ] \
  && ok "every rung failing the check -> blocked, exit 3 (surfaced, not spun)" \
  || bad "ladder exhaustion wrong (state=$s rc=$rc)"
[ "$(grep -c . "$MOCK_MODELS")" -eq 2 ] \
  && ok "exhaustion spent each rung exactly once (per-tier 1), no spin" \
  || bad "exhaustion spent the wrong amount: $(tr '\n' ' ' < "$MOCK_MODELS")"

# 9. STALL = ESCALATE, not blocked: the identical failure twice on one rung means THAT model is
#    stuck and capability remains above, so the loop climbs rather than stopping.
export MOCK_MODELS="$TMP/m_st"; export MOCK_CNT="$TMP/c_st"; : > "$MOCK_MODELS"; : > "$MOCK_CNT"
s="$(cmd_loop escalate --ladder "glm-5.2,fable" --per-tier 9 --max 9 --check "false" "task" 2>/dev/null)"; rc=$?
[ "$s" = blocked ] && [ "$rc" -eq 3 ] \
  && [ "$(grep -cx 'glm-5.2' "$MOCK_MODELS")" -eq 2 ] && [ "$(grep -cx 'fable' "$MOCK_MODELS")" -eq 2 ] \
  && ok "identical failure twice on a rung escalates to the next tier (2 cheap, then 2 expensive, then blocked at the top)" \
  || bad "stall-escalation wrong (state=$s rc=$rc models: $(tr '\n' ' ' < "$MOCK_MODELS"))"

# 10. --max bounds TOTAL attempts across the whole ladder: a runaway guard, hit even while
#     escalation would still have rungs left.
export MOCK_MODELS="$TMP/m_mt"; export MOCK_CNT="$TMP/c_mt"; : > "$MOCK_MODELS"; : > "$MOCK_CNT"
s="$(cmd_loop escalate --ladder "haiku,glm-5.2,fable" --max 2 --per-tier 9 \
      --check "cat '$MOCK_CNT'; false" "task" 2>/dev/null)"; rc=$?
[ "$s" = max_turns ] && [ "$rc" -eq 2 ] \
  && [ "$(grep -c . "$MOCK_MODELS")" -eq 2 ] && [ "$(sort -u "$MOCK_MODELS" | tr -d ' ')" = "haiku" ] \
  && ok "--max stops the loop mid-ladder -> max_turns, exit 2 (only the cheap rung spent)" \
  || bad "--max bound wrong (state=$s rc=$rc models: $(tr '\n' ' ' < "$MOCK_MODELS"))"

# 11. --max-minutes: the wall-clock bound stops a loop the attempt cap would let grind on.
export MOCK_MODELS="$TMP/m_tm"; export MOCK_CNT="$TMP/c_tm"; : > "$MOCK_MODELS"; : > "$MOCK_CNT"
s="$(MOCK_SLEEP=1 cmd_loop escalate --ladder "glm-5.2,fable" --max 99 --per-tier 9 --max-minutes 0.05 \
      --check "echo x >> '$TMP/tick'; cat '$TMP/tick'; false" "task" 2>/dev/null)"; rc=$?
[ "$s" = max_time ] && [ "$rc" -eq 2 ] \
  && ok "the time bound stops a non-converging escalate loop -> max_time, exit 2" \
  || bad "time bound did not fire (state=$s rc=$rc)"

# 12. Guard values are validated, not silently coerced (a mistyped bound that becomes 0 turns a
#     runaway guard off entirely).
( cmd_loop escalate --check true --per-tier abc "t" >/dev/null 2>&1 ); [ $? -ne 0 ] \
  && ok "a non-numeric --per-tier is rejected" || bad "--per-tier accepted a non-number"
( cmd_loop escalate --check true --per-tier 0 "t" >/dev/null 2>&1 ); [ $? -ne 0 ] \
  && ok "--per-tier 0 is rejected (0 retries would make the cheap rung decorative)" || bad "--per-tier accepted 0"
( cmd_loop escalate --check true --max-minutes abc "t" >/dev/null 2>&1 ); [ $? -ne 0 ] \
  && ok "a non-numeric time bound is rejected rather than silently disabled" || bad "--max-minutes accepted a non-number"

# 13. FOREGROUND CONTRACT: every delegation runs with auto-detach disabled, on every tier — a
#     detached delegate would let the check grade stale files AND spend the next rung's money on
#     a false failure.
export MOCK_MODELS="$TMP/m_fg"; export MOCK_CNT="$TMP/c_fg"; : > "$MOCK_MODELS"; : > "$MOCK_CNT"
ENVCAP="$TMP/envcap_esc"; : > "$ENVCAP"
MOCK_MODELS="$MOCK_MODELS" MOCK_CNT="$MOCK_CNT" ENVCAP="$ENVCAP" \
  cmd_loop escalate --ladder "glm-5.2,fable" --per-tier 1 --check 'grep -qx fable "$MOCK_MODELS"' "task" >/dev/null 2>&1
[ "$(sort -u "$ENVCAP" | tr -d ' ')" = "1" ] && [ "$(grep -c . "$ENVCAP")" -eq 2 ] \
  && ok "delegates on BOTH tiers run in the foreground (OSRC_NO_AUTODETACH=1), so the check grades real edits" \
  || bad "a delegate was not forced foreground: $(tr '\n' ' ' < "$ENVCAP")"

# 14. A delegate BLOCKED is not a capability gap: a pricier model hits the same wall, so the loop
#     stops for a human instead of spending its way up the ladder.
export MOCK_MODELS="$TMP/m_bl"; export MOCK_CNT="$TMP/c_bl"; : > "$MOCK_MODELS"; : > "$MOCK_CNT"
s="$(MOCK_BLOCK=1 cmd_loop escalate --ladder "haiku,glm-5.2,fable" --per-tier 1 --max 6 --check "false" "task" 2>/dev/null)"; rc=$?
[ "$s" = blocked ] && [ "$rc" -eq 3 ] && [ "$(grep -c . "$MOCK_MODELS")" -eq 1 ] \
  && ok "delegate BLOCKED -> blocked after ONE attempt (escalating price cannot fix a human-needed block)" \
  || bad "blocked path wrong (state=$s rc=$rc attempts=$(grep -c . "$MOCK_MODELS"))"

# 15. An escalate loop is observable like any loop: state, attempt, current tier, and the latest
#     failure on disk, and it shows up in `loop status`.
export MOCK_MODELS="$TMP/m_ob"; export MOCK_CNT="$TMP/c_ob"; : > "$MOCK_MODELS"; : > "$MOCK_CNT"
cmd_loop escalate --ladder "glm-5.2,fable" --per-tier 1 --check "echo 'FAIL: thing broke'; false" --max 3 "t" >/dev/null 2>&1
_ld="$(ls -dt "$OSRC_HOME/loops"/*/ 2>/dev/null | head -1)"
[ -f "$_ld/attempt" ] && [ -f "$_ld/rung" ] \
  && ok "the loop records which attempt AND which tier it is on, not just the verdict" \
  || bad "no live per-attempt/per-tier state written"
grep -q 'thing broke' "$_ld/last_fail" 2>/dev/null \
  && ok "the latest failure is readable without opening every check file" \
  || bad "no last-failure summary recorded"
out="$(cmd_loop status 2>/dev/null)"
printf '%s' "$out" | grep -q "$(basename "$_ld")" \
  && ok "loop status surfaces the escalate loop alongside verify loops" \
  || bad "loop status does not list the escalate loop"

# 16. `loop resume` refuses escalate loops: the rung position and per-tier stall budget are not
#     saved, so resuming would silently grade a fresh ladder against old feedback.
e="$( ( cmd_loop resume "$(basename "$_ld")" --max 9 ) 2>&1 )"
[ $? -ne 0 ] && printf '%s' "$e" | grep -qi 'escalate' \
  && ok "loop resume refuses an escalate loop, saying why" \
  || bad "resume of an escalate loop was not refused"

# 17. The guidance names the new shape with its use-case, so picking it never requires reading
#     the source.
e="$( ( cmd_loop ) 2>&1 )"
printf '%s' "$e" | grep -q 'loop escalate' \
  && ok "the loop help offers escalate alongside verify" || bad "loop help omits escalate"
printf '%s' "$e" | grep -qi 'cheap' \
  && ok "the guidance says what escalate is FOR (cheap first, pay more only on failure)" \
  || bad "loop help names escalate without saying when to pick it"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
