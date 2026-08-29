#!/bin/bash
# test_require_interactive.sh — BUG 1: a would-be headless auto-detach must route to an INTERACTIVE
# tmux session (OSRC_REQUIRE_INTERACTIVE=1, the default), NOT a headless bg job. Absence of a TTY is
# NOT evidence that nobody is watching — every agent harness has no TTY on either stream.
#
# Tests:
#   (a) Default gate ON + non-TTY slow lane → tmux new-session + send-keys called, NO bg job.
#       Assert the send-keys command contains OSRC_NO_AUTODETACH=1 (fork-bomb guard) + the verb.
#   (b) tmux new-session fails → engine DIES LOUDLY (never silently falls back to headless bg).
#   (c) OSRC_REQUIRE_INTERACTIVE=0 → bg job created (opt-out to headless works).
#   (d) OSRC_NO_AUTODETACH=1 → foreground, no tmux, no bg job.
#   (e) Structural: `have tmux || die` gate present in source (tmux-unavailable die-loudly check).
#
# Uses FAKES — never a live model call, never a real tmux session.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$DIR/outsourcerer.sh"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

TMPDIR_RI="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RI" 2>/dev/null' EXIT

# ---- fake devin (same shape as test_autodetach.sh) ----
FAKE_HOME="$TMPDIR_RI/fake-home"
FAKE_BIN="$FAKE_HOME/.local/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/devin" <<'FAKE_DEVIN'
#!/bin/bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  echo "Logged in as test-user"
  exit 0
fi
echo "FAKE DEVIN RESULT: test task completed"
echo "OSRC::DONE"
exit 7
FAKE_DEVIN
chmod +x "$FAKE_BIN/devin"

# ---- fake tmux: records all calls, controllable failure ----
cat > "$FAKE_BIN/tmux" <<'FAKE_TMUX'
#!/bin/bash
# Records every invocation to $OSRC_FAKE_TMUX_DIR/all-calls (one line per call, space-joined args).
# If OSRC_FAKE_TMUX_FAIL_NEW is set, `new-session` exits 1 (simulates a broken/unavailable tmux).
if [ -n "${OSRC_FAKE_TMUX_DIR:-}" ]; then
  printf '%s\n' "$*" >> "$OSRC_FAKE_TMUX_DIR/all-calls"
fi
case "${1:-}" in
  new-session)
    [ -n "${OSRC_FAKE_TMUX_FAIL_NEW:-}" ] && exit 1
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
FAKE_TMUX
chmod +x "$FAKE_BIN/tmux"

echo "=== (a) Default OSRC_REQUIRE_INTERACTIVE=1 → interactive tmux, no bg job ==="
{
  RI_HOME_A="$TMPDIR_RI/home-a"
  RI_JOBS_A="$RI_HOME_A/jobs"
  RI_TMUX_A="$TMPDIR_RI/tmux-a"
  mkdir -p -m 700 "$RI_HOME_A" "$RI_TMUX_A"

  RI_A_OUT="$(HOME="$FAKE_HOME" \
    OSRC_HOME="$RI_HOME_A" \
    OSRC_CLOUD_ACK=1 OSRC_CLOUD_ACKED=1 \
    OSRC_FORCE_AUTODETACH=1 \
    OSRC_HEARTBEAT_DISABLED=1 \
    OSRC_CATALOG_VALIDATE=0 \
    OUTSOURCERER_DEPTH=0 \
    OSRC_FAKE_TMUX_DIR="$RI_TMUX_A" \
    bash "$ENGINE" run -m glm-5.2 "test task" 2>"$TMPDIR_RI/a-stderr" </dev/null)"
  RI_A_RC=$?
  RI_A_STDERR="$(cat "$TMPDIR_RI/a-stderr" 2>/dev/null)"
  RI_A_JOBS="$(find "$RI_JOBS_A" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  RI_A_TMUX_CALLS="$(cat "$RI_TMUX_A/all-calls" 2>/dev/null || echo '')"

  # (a1) Engine returned 0 + a session name on stdout.
  if [ "$RI_A_RC" -eq 0 ] && printf '%s' "$RI_A_OUT" | grep -q '^osrc-ad-'; then
    ok "(a) engine returned 0 + osrc-ad- session name on stdout"
  else
    no "(a) engine failed or no session name (rc=$RI_A_RC, output=[$RI_A_OUT])"
  fi

  # (a2) NO bg job was created (the interactive path does NOT use _bg_launch).
  if [ "$RI_A_JOBS" -eq 0 ]; then
    ok "(a) no bg job created (interactive tmux path, not headless bg)"
  else
    no "(a) bg job created ($RI_A_JOBS) — interactive path did not fire?"
  fi

  # (a3) tmux new-session was called.
  if printf '%s' "$RI_A_TMUX_CALLS" | grep -q 'new-session'; then
    ok "(a) tmux new-session called (interactive tmux machinery)"
  else
    no "(a) tmux new-session NOT called (all-calls=[$RI_A_TMUX_CALLS])"
  fi

  # (a4) tmux send-keys was called with OSRC_NO_AUTODETACH=1 (fork-bomb guard) + the verb.
  if printf '%s' "$RI_A_TMUX_CALLS" | grep -q 'send-keys' \
     && printf '%s' "$RI_A_TMUX_CALLS" | grep -q 'OSRC_NO_AUTODETACH=1' \
     && printf '%s' "$RI_A_TMUX_CALLS" | grep -q 'run'; then
    ok "(a) tmux send-keys has OSRC_NO_AUTODETACH=1 + verb (fork-bomb guard + re-entry command)"
  else
    no "(a) send-keys missing OSRC_NO_AUTODETACH=1 or verb (all-calls=[$RI_A_TMUX_CALLS])"
  fi

  # (a5) The steering hint on stderr shows OUTSOURCERER_TMUX=<name> + session subcommands.
  if printf '%s' "$RI_A_STDERR" | grep -q 'OUTSOURCERER_TMUX=' \
     && printf '%s' "$RI_A_STDERR" | grep -q 'session read' \
     && printf '%s' "$RI_A_STDERR" | grep -q 'session send' \
     && printf '%s' "$RI_A_STDERR" | grep -q 'session stop'; then
    ok "(a) stderr steering hint has OUTSOURCERER_TMUX + session read/send/stop"
  else
    no "(a) steering hint missing OUTSOURCERER_TMUX or session subcommands (stderr=[$RI_A_STDERR])"
  fi

  # (a6) The stderr says INTERACTIVE, not headless bg.
  if printf '%s' "$RI_A_STDERR" | grep -q 'INTERACTIVE'; then
    ok "(a) stderr says INTERACTIVE tmux (not headless bg)"
  else
    no "(a) stderr missing INTERACTIVE label (stderr=[$RI_A_STDERR])"
  fi
}

echo ""
echo "=== (b) tmux new-session fails → die loudly, no silent headless fallback ==="
{
  RI_HOME_B="$TMPDIR_RI/home-b"
  RI_JOBS_B="$RI_HOME_B/jobs"
  RI_TMUX_B="$TMPDIR_RI/tmux-b"
  mkdir -p -m 700 "$RI_HOME_B" "$RI_TMUX_B"

  RI_B_OUT="$(HOME="$FAKE_HOME" \
    OSRC_HOME="$RI_HOME_B" \
    OSRC_CLOUD_ACK=1 OSRC_CLOUD_ACKED=1 \
    OSRC_FORCE_AUTODETACH=1 \
    OSRC_HEARTBEAT_DISABLED=1 \
    OSRC_CATALOG_VALIDATE=0 \
    OUTSOURCERER_DEPTH=0 \
    OSRC_FAKE_TMUX_DIR="$RI_TMUX_B" \
    OSRC_FAKE_TMUX_FAIL_NEW=1 \
    bash "$ENGINE" run -m glm-5.2 "test task" 2>"$TMPDIR_RI/b-stderr" </dev/null)"
  RI_B_RC=$?
  RI_B_STDERR="$(cat "$TMPDIR_RI/b-stderr" 2>/dev/null)"
  RI_B_JOBS="$(find "$RI_JOBS_B" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"

  # (b1) Engine exited non-zero (died loudly).
  if [ "$RI_B_RC" -ne 0 ]; then
    ok "(b) engine died loudly on tmux new-session failure (rc=$RI_B_RC)"
  else
    no "(b) engine returned 0 on tmux failure — should have died (output=[$RI_B_OUT])"
  fi

  # (b2) The error message names tmux + OSRC_REQUIRE_INTERACTIVE (the escape hatch).
  if printf '%s' "$RI_B_STDERR" | grep -qi 'tmux' \
     && printf '%s' "$RI_B_STDERR" | grep -q 'OSRC_REQUIRE_INTERACTIVE'; then
    ok "(b) error message names tmux + OSRC_REQUIRE_INTERACTIVE (actionable reason)"
  else
    no "(b) error message missing tmux or OSRC_REQUIRE_INTERACTIVE (stderr=[$RI_B_STDERR])"
  fi

  # (b3) NO bg job was created (never silently fell back to headless).
  if [ "$RI_B_JOBS" -eq 0 ]; then
    ok "(b) no bg job created (never silently fell back to headless)"
  else
    no "(b) bg job created ($RI_B_JOBS) — silently fell back to headless!"
  fi
}

echo ""
echo "=== (c) OSRC_REQUIRE_INTERACTIVE=0 → bg job created (opt-out works) ==="
{
  RI_HOME_C="$TMPDIR_RI/home-c"
  RI_JOBS_C="$RI_HOME_C/jobs"
  RI_TMUX_C="$TMPDIR_RI/tmux-c"
  mkdir -p -m 700 "$RI_HOME_C" "$RI_TMUX_C"

  RI_C_OUT="$(HOME="$FAKE_HOME" \
    OSRC_HOME="$RI_HOME_C" \
    OSRC_CLOUD_ACK=1 OSRC_CLOUD_ACKED=1 \
    OSRC_FORCE_AUTODETACH=1 \
    OSRC_REQUIRE_INTERACTIVE=0 \
    OSRC_HEARTBEAT_DISABLED=1 \
    OSRC_CATALOG_VALIDATE=0 \
    OUTSOURCERER_DEPTH=0 \
    OSRC_POLL=1 \
    OSRC_FAKE_TMUX_DIR="$RI_TMUX_C" \
    bash "$ENGINE" run -m glm-5.2 "test task" 2>"$TMPDIR_RI/c-stderr" </dev/null)"
  RI_C_RC=$?
  RI_C_JOBS="$(find "$RI_JOBS_C" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  RI_C_TMUX_CALLS="$(cat "$RI_TMUX_C/all-calls" 2>/dev/null || echo '')"

  # (c1) Engine returned 0 + a job id (bg path).
  if [ "$RI_C_RC" -eq 0 ] && [ -n "$RI_C_OUT" ]; then
    ok "(c) engine returned 0 + output (bg path opt-out)"
  else
    no "(c) engine failed (rc=$RI_C_RC, output=[$RI_C_OUT])"
  fi

  # (c2) A bg job was created (the headless bg path was taken).
  if [ "$RI_C_JOBS" -ge 1 ]; then
    ok "(c) bg job created ($RI_C_JOBS) — OSRC_REQUIRE_INTERACTIVE=0 opts out to headless bg"
  else
    no "(c) no bg job created — opt-out to bg path did not work"
  fi

  # (c3) tmux new-session was NOT called (the bg path doesn't use tmux).
  if ! printf '%s' "$RI_C_TMUX_CALLS" | grep -q 'new-session'; then
    ok "(c) tmux new-session NOT called (bg path, not interactive)"
  else
    no "(c) tmux new-session was called — bg path should not use tmux (all-calls=[$RI_C_TMUX_CALLS])"
  fi
}

echo ""
echo "=== (d) OSRC_NO_AUTODETACH=1 → foreground, no tmux, no bg job ==="
{
  RI_HOME_D="$TMPDIR_RI/home-d"
  RI_JOBS_D="$RI_HOME_D/jobs"
  RI_TMUX_D="$TMPDIR_RI/tmux-d"
  mkdir -p -m 700 "$RI_HOME_D" "$RI_TMUX_D"

  RI_D_OUT="$(HOME="$FAKE_HOME" \
    OSRC_HOME="$RI_HOME_D" \
    OSRC_CLOUD_ACK=1 OSRC_CLOUD_ACKED=1 \
    OSRC_NO_AUTODETACH=1 \
    OSRC_HEARTBEAT_DISABLED=1 \
    OSRC_CATALOG_VALIDATE=0 \
    OUTSOURCERER_DEPTH=0 \
    OSRC_FG_GUARD=0 \
    OSRC_FAKE_TMUX_DIR="$RI_TMUX_D" \
    bash "$ENGINE" run -m glm-5.2 "test task" 2>"$TMPDIR_RI/d-stderr" </dev/null)"
  RI_D_RC=$?
  RI_D_JOBS="$(find "$RI_JOBS_D" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  RI_D_TMUX_CALLS="$(cat "$RI_TMUX_D/all-calls" 2>/dev/null || echo '')"

  # (d1) No bg job (foreground path).
  if [ "$RI_D_JOBS" -eq 0 ]; then
    ok "(d) no bg job created (OSRC_NO_AUTODETACH=1 forces foreground)"
  else
    no "(d) bg job created ($RI_D_JOBS) — NO_AUTODETACH should force foreground"
  fi

  # (d2) tmux new-session NOT called (foreground, not interactive).
  if ! printf '%s' "$RI_D_TMUX_CALLS" | grep -q 'new-session'; then
    ok "(d) tmux new-session NOT called (foreground, not interactive)"
  else
    no "(d) tmux new-session called — foreground should not use tmux (all-calls=[$RI_D_TMUX_CALLS])"
  fi

  # (d3) The fake devin ran (foreground output present).
  if printf '%s' "$RI_D_OUT" | grep -q "FAKE DEVIN RESULT"; then
    ok "(d) fake devin ran foreground (output present)"
  else
    no "(d) fake devin output missing (output=[$RI_D_OUT])"
  fi
}

echo ""
echo "=== (e) Structural: have tmux || die gate present in source ==="
{
  # The die-loudly check for tmux-unavailable must be in the auto-detach interactive path.
  if grep -q 'have tmux || die.*OSRC_REQUIRE_INTERACTIVE' "$ENGINE"; then
    ok "(e) structural: have tmux || die gate present (tmux-unavailable dies loudly)"
  else
    no "(e) structural: have tmux || die gate missing from auto-detach interactive path"
  fi

  # OSRC_REQUIRE_INTERACTIVE must be referenced in _autodetach_run.
  if grep -q 'OSRC_REQUIRE_INTERACTIVE' "$ENGINE"; then
    ok "(e) structural: OSRC_REQUIRE_INTERACTIVE referenced in source"
  else
    no "(e) structural: OSRC_REQUIRE_INTERACTIVE not referenced"
  fi

  # The interactive path must use tmux new-session + send-keys (same as session start).
  if grep -q 'tmux new-session.*osrc-ad\|_ad_sess' "$ENGINE" \
     && grep -q 'tmux send-keys.*_ad_sess' "$ENGINE"; then
    ok "(e) structural: interactive path uses tmux new-session + send-keys"
  else
    no "(e) structural: interactive path missing tmux new-session or send-keys"
  fi

  # The bg path must still exist (opt-out).
  if grep -q 'OSRC_REQUIRE_INTERACTIVE.*!=.*1.*_bg_launch\|_bg_launch.*_ar_verb' "$ENGINE"; then
    ok "(e) structural: bg path preserved as opt-out (OSRC_REQUIRE_INTERACTIVE=0)"
  else
    no "(e) structural: bg path opt-out missing"
  fi

  # OUTSOURCERER_TMUX steering hint must be printed.
  if grep -q 'OUTSOURCERER_TMUX=%s.*session read.*session send.*session stop' "$ENGINE"; then
    ok "(e) structural: OUTSOURCERER_TMUX steering hint printed (read/send/stop)"
  else
    no "(e) structural: OUTSOURCERER_TMUX steering hint missing"
  fi
}

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
