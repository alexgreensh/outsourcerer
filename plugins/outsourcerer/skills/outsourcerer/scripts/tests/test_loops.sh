#!/usr/bin/env bash
# test_loops.sh — the built-in `loop verify` primitive: bounded delegate->external-check->retry,
# terminating into exactly one honest state (success/blocked/max_turns), with a stall guard.
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

# Source the script with the main dispatcher stripped, so cmd_loop/_new_job_id/die are defined.
sed '/^[[:space:]]*main "\$@"[[:space:]]*$/d' "$SRC" > "$TMP/src.sh"
set +e; . "$TMP/src.sh" >/dev/null 2>&1; set +e

# Mock delegate: records that it ran (grows a counter), optionally emits BLOCKED.
MOCK="$TMP/mock.sh"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
echo "run" >> "$MOCK_CNT"
[ -n "${MOCK_BLOCK:-}" ] && echo "OSRC::BLOCKED need a human decision"
exit 0
EOF
chmod +x "$MOCK"
SCRIPT_PATH="$MOCK"   # cmd_loop delegates via "$SCRIPT_PATH"

# 1. --check is mandatory (external verification never optional).
( cmd_loop verify "do a thing" >/dev/null 2>&1 ); [ $? -ne 0 ] && ok "loop verify requires --check (external verification mandatory)" || bad "missing --check did not error"

# 2. a task is mandatory.
( cmd_loop verify --check "true" >/dev/null 2>&1 ); [ $? -ne 0 ] && ok "loop verify requires a task" || bad "missing task did not error"

# 3. unknown shape errors and points at the recipes.
e="$( ( cmd_loop sweep --check true "x" ) 2>&1 )"; echo "$e" | grep -qi 'recipe' && ok "non-verify shape points to references/loops.md recipes" || bad "unknown shape message unhelpful"

# 4. SUCCESS: check passes on attempt 1 -> state success, exit 0, delegate ran exactly once.
export MOCK_CNT="$TMP/c_ok"; : > "$MOCK_CNT"
s="$(MOCK_CNT="$MOCK_CNT" cmd_loop verify --check "true" --max 3 "make it pass" 2>/dev/null)"; rc=$?
[ "$s" = success ] && [ "$rc" -eq 0 ] && ok "check passes -> state=success, exit 0" || bad "success path wrong (state=$s rc=$rc)"
[ "$(grep -c run "$MOCK_CNT")" -eq 1 ] && ok "success stopped after 1 attempt (no wasted retries)" || bad "success did not stop early"

# 5. MAX_TURNS: check never passes AND output differs each attempt (grows) -> runs to the cap.
export MOCK_CNT="$TMP/c_max"; : > "$MOCK_CNT"
s="$(MOCK_CNT="$MOCK_CNT" cmd_loop verify --check "cat '$MOCK_CNT'; false" --max 3 "task" 2>/dev/null)"; rc=$?
[ "$s" = max_turns ] && [ "$rc" -eq 2 ] && ok "never-passing check with changing output -> max_turns, exit 2" || bad "max_turns path wrong (state=$s rc=$rc)"
[ "$(grep -c run "$MOCK_CNT")" -eq 3 ] && ok "max_turns ran exactly --max=3 attempts" || bad "max_turns attempt count wrong ($(grep -c run "$MOCK_CNT"))"

# 6. STALL GUARD: identical failure twice (empty output from `false`) -> blocked before the cap.
export MOCK_CNT="$TMP/c_stall"; : > "$MOCK_CNT"
s="$(MOCK_CNT="$MOCK_CNT" cmd_loop verify --check "false" --max 5 "task" 2>/dev/null)"; rc=$?
[ "$s" = blocked ] && [ "$rc" -eq 3 ] && ok "identical failure twice -> blocked (stall guard), exit 3" || bad "stall guard wrong (state=$s rc=$rc)"
[ "$(grep -c run "$MOCK_CNT")" -le 2 ] && ok "stall guard stopped by attempt 2 (didn't burn all 5)" || bad "stall guard didn't stop early ($(grep -c run "$MOCK_CNT"))"

# 7. BLOCKED: the delegate emits OSRC::BLOCKED -> distinct blocked state, surfaced not swallowed.
export MOCK_CNT="$TMP/c_blk"; : > "$MOCK_CNT"
s="$(MOCK_CNT="$MOCK_CNT" MOCK_BLOCK=1 cmd_loop verify --check "false" --max 3 "task" 2>/dev/null)"; rc=$?
[ "$s" = blocked ] && [ "$rc" -eq 3 ] && ok "delegate BLOCKED -> state=blocked, exit 3 (surfaced for a human)" || bad "blocked path wrong (state=$s rc=$rc)"

# 8. FOREGROUND CONTRACT: the delegate must be invoked with auto-detach disabled. A detached delegate
#    returns instantly, so the acceptance check would grade files it has not written yet — every
#    attempt sees the same pre-edit failure and the loop reports a confident, wrong verdict.
export MOCK_CNT="$TMP/c_env"; : > "$MOCK_CNT"
ENVCAP="$TMP/envcap"; : > "$ENVCAP"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
echo "run" >> "$MOCK_CNT"
echo "${OSRC_NO_AUTODETACH:-unset}" >> "$ENVCAP"
exit 0
EOF
chmod +x "$MOCK"
MOCK_CNT="$MOCK_CNT" ENVCAP="$ENVCAP" cmd_loop verify --check "true" --max 1 "task" >/dev/null 2>&1
[ "$(head -1 "$ENVCAP")" = "1" ] && ok "delegate runs in the foreground (OSRC_NO_AUTODETACH=1) so the check grades real edits" || bad "delegate not forced foreground (got '$(head -1 "$ENVCAP")') — check would grade stale files"

# 9. REFUSE-TO-GRADE: if a delegate detaches anyway, the loop must NOT emit a verdict — even when the
#    acceptance check would pass, because that pass would be about work the delegate never did.
export MOCK_CNT="$TMP/c_det"; : > "$MOCK_CNT"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
echo "run" >> "$MOCK_CNT"
echo ">>> [auto-detach] non-interactive slow-lane run detached to bg to avoid a caller tool-timeout."
echo "20260101-000000-deadbeef"
exit 0
EOF
chmod +x "$MOCK"
s="$(MOCK_CNT="$MOCK_CNT" cmd_loop verify --check "true" --max 3 "task" 2>/dev/null)"; rc=$?
[ "$s" = blocked ] && [ "$rc" -eq 3 ] && ok "detached delegate -> refuses to grade (blocked), never a false success" || bad "detached delegate produced a verdict anyway (state=$s rc=$rc)"

# 10. --worktree must fail loudly rather than silently verify the wrong tree. The delegate runs in the
#     foreground and the acceptance check runs in the caller's cwd, so nothing here establishes an
#     isolated tree; accepting the flag would grade files the delegate never touched.
e="$( ( cmd_loop verify --worktree --check "true" -m x "task" ) 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$e" | grep -qi 'not supported yet' \
  && ok "--worktree is refused with a reason, not silently ignored" \
  || bad "--worktree did not fail loudly (rc=$rc)"
printf '%s' "$e" | grep -qi 'bg --worktree' \
  && ok "--worktree refusal names the working alternative" \
  || bad "--worktree refusal gives no alternative"

# 11. Knowing loops exist is not the same as knowing which one to run. Listing the shapes without
#     selection criteria pushes the hardest decision back onto the user at the exact moment they have
#     the least context, and a wrong choice here wastes a whole run.
e="$( ( cmd_loop ) 2>&1 )"
printf '%s' "$e" | grep -qi 'which loop do you want' \
  && ok "the loop help asks the selection question instead of only listing shapes" \
  || bad "loop help lists shapes with no guidance on choosing"
for shape in sweep best-of-N evaluator-optimizer council-build; do
  printf '%s' "$e" | grep -q "$shape" || bad "selection guidance omits $shape"
done
printf '%s' "$e" | grep -qi 'do not loop' \
  && ok "the guidance also says when NOT to loop (no checker means no loop)" \
  || bad "no guidance on when looping is the wrong tool"
ok "selection guidance names every recipe"

# 12. The GOAL ends the loop, not the cap. A passing check must stop it immediately even when a huge
#     attempt budget and a long time bound are available — otherwise the guards are being treated as
#     targets and every success costs the full budget.
export MOCK_CNT="$TMP/c_goal"; : > "$MOCK_CNT"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
echo "run" >> "$MOCK_CNT"
exit 0
EOF
chmod +x "$MOCK"
s="$(MOCK_CNT="$MOCK_CNT" cmd_loop verify --check "true" --max 99 --max-minutes 60 "task" 2>/dev/null)"
{ [ "$s" = success ] && [ "$(grep -c run "$MOCK_CNT")" -eq 1 ]; } \
  && ok "a passing check ends the loop at once, however large the guards are" \
  || bad "the loop kept going past its goal (state=$s attempts=$(grep -c run "$MOCK_CNT"))"

# 13. A wall-clock bound must be able to stop a loop a round count would let run for ages. Rounds are
#     not equal work, so time is the better guard on open-ended tasks.
export MOCK_CNT="$TMP/c_time"; : > "$MOCK_CNT"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
echo "run" >> "$MOCK_CNT"
sleep 1
exit 0
EOF
chmod +x "$MOCK"
s="$(MOCK_CNT="$MOCK_CNT" cmd_loop verify --check "echo x >> $TMP/tick; cat $TMP/tick; false" --max 999 --max-minutes 0.05 "task" 2>/dev/null)"
[ "$s" = max_time ] \
  && ok "the time bound stops a non-converging loop the attempt cap would not" \
  || bad "time bound did not fire (state=$s)"

# 14. Guard values must be validated, not silently coerced: a mistyped bound that becomes 0 turns a
#     runaway guard off entirely, which is the opposite of what the user asked for.
( cmd_loop verify --check true --max-minutes abc "t" >/dev/null 2>&1 ); [ $? -ne 0 ] \
  && ok "a non-numeric time bound is rejected rather than silently disabled" \
  || bad "--max-minutes accepted a non-number"

# 15. The stall guard must survive REAL test output. Byte-comparison is defeated by any suite that
#     prints a duration, timestamp, temp path or run id — the failure is identical, the bytes are not,
#     so the guard never fires and the loop burns its whole budget re-reporting the same thing.
export MOCK_CNT="$TMP/c_noise"; : > "$MOCK_CNT"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
echo "run" >> "$MOCK_CNT"
exit 0
EOF
chmod +x "$MOCK"
s="$(MOCK_CNT="$MOCK_CNT" cmd_loop verify --max 9 \
      --check 'echo "[$(date +%H:%M:%S)] FAIL: auth::test_login took 0.42s"; false' "t" 2>/dev/null)"
{ [ "$s" = blocked ] && [ "$(grep -c run "$MOCK_CNT")" -le 3 ]; } \
  && ok "the same failure wearing a fresh timestamp still counts as no progress" \
  || bad "noisy-but-identical failures did not trip the stall guard (state=$s attempts=$(grep -c run "$MOCK_CNT"))"

# 16. ...and the opposite error is worse: stopping a loop that IS getting somewhere. Shrinking failure
#     counts are progress, so small integers must survive the comparison even though timestamps do not.
export MOCK_CNT="$TMP/c_conv"; : > "$MOCK_CNT"
CNT="$TMP/conv_n"; echo 4 > "$CNT"
s="$(MOCK_CNT="$MOCK_CNT" cmd_loop verify --max 9 \
      --check "n=\$(cat $CNT); n=\$((n-1)); echo \$n > $CNT; for i in \$(seq 1 \$n); do echo \"FAIL test_\$i\"; done; [ \$n -eq 0 ]" "t" 2>/dev/null)"
[ "$s" = success ] \
  && ok "a loop whose failures are shrinking is allowed to finish" \
  || bad "a converging loop was wrongly stopped (state=$s)"

# 17. A loop must be observable WHILE it runs. State written only at the end is unreadable exactly
#     when it matters — you cannot tell grinding-usefully from stuck, so you cannot steer or kill it.
export MOCK_CNT="$TMP/c_live"; : > "$MOCK_CNT"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
echo "run" >> "$MOCK_CNT"
exit 0
EOF
chmod +x "$MOCK"
MOCK_CNT="$MOCK_CNT" cmd_loop verify --check "echo 'FAIL: thing broke'; false" --max 2 "t" >/dev/null 2>&1
_ld="$(ls -dt "$OSRC_HOME/loops"/*/ 2>/dev/null | head -1)"
[ -f "$_ld/attempt" ] && ok "the loop records which attempt it is on, not just the verdict" \
  || bad "no per-attempt state written (a running loop is unobservable)"
grep -q 'thing broke' "$_ld/last_fail" 2>/dev/null \
  && ok "the latest failure is readable without opening every check file" \
  || bad "no last-failure summary recorded"
out="$(cmd_loop status 2>/dev/null)"
printf '%s' "$out" | grep -q 'LAST FAILURE' \
  && ok "loop status surfaces state, attempt, elapsed and the current failure" \
  || bad "loop status does not report live state"

# 18. Spend must be reported in units that BIND. On a subscription lane the dollar figure is always
#     zero while the plan's rate limit is what actually runs out, so attempts and time are the truth.
out="$(MOCK_CNT="$MOCK_CNT" cmd_loop verify --check "true" --max 3 "t" 2>&1 >/dev/null)"
printf '%s' "$out" | grep -qi 'attempt(s) over' \
  && ok "a finished loop reports what it consumed" || bad "loop does not report its consumption"
printf '%s' "$out" | grep -qi 'even when it bills' \
  && ok "the report says a \$0 lane still burns plan limits" \
  || bad "consumption report implies a \$0 lane costs nothing"

# 19. The stall normaliser must not rely on GNU-only regex. `\b` is silently IGNORED by BSD sed, so
#     durations were never stripped on macOS and the guard was weaker than its tests implied — the
#     third GNU-vs-BSD divergence found in this codebase, so it gets a permanent check.
grep -v '^[[:space:]]*#' "$SRC" | grep -q '\\b' \
  && bad "a GNU-only \\b word boundary is back in the source (BSD sed ignores it silently)" \
  || ok "no GNU-only word boundaries in the source"
a="$(printf 'FAIL auth took 0.42s\n' | _check_signature)"
b="$(printf 'FAIL auth took 9.91s\n' | _check_signature)"
[ "$a" = "$b" ] && ok "two runs of the same failure with different durations compare equal" \
  || bad "durations still make identical failures look different ([$a] vs [$b])"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
