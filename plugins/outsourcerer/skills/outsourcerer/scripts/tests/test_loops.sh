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

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
