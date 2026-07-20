#!/usr/bin/env bash
# test_devin_tls_diagnostics.sh — devin sandboxed-proxy TLS failure diagnostics (additive, no
# retry/routing change). Asserts the narrow detector fires on the rustls/OSStatus/chisel signature
# in devin's own CLI log, does NOT false-positive on ordinary task/test output or the generic
# "Connection error" devin prints, and that the hint surfaces through delegate()/result/logs
# without double-printing and without touching _is_transport_failure's existing classifications.
# Run: bash test_devin_tls_diagnostics.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
if [ ! -f "$SRC" ]; then echo FAIL: cannot find "$SRC"; exit 1; fi
bash -n "$SRC" || { echo FAIL: bash -n failed for "$SRC"; exit 1; }

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
export HOME="$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Source the main script. main runs with no args and prints help (suppressed); functions stay defined.
. "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok()  { echo PASS: $1; pass=$((pass+1)); }
bad() { echo FAIL: $1; fail=$((fail+1)); }

# --- Scenario 1: _is_sandboxed_proxy_tls_failure unit classifications. ---
# Positive: the exact signature from devin's own CLI log (rustls_platform_verifier + OSStatus).
rustls_fixture='2026-07-18T22:14:02.103Z ERROR rustls_platform_verifier::verification::apple: failed to verify TLS certificate: invalid peer certificate: Other(OtherError("OSStatus -26276: -26276"))
2026-07-18T22:14:02.104Z WARN  chisel_cloud_bridge::handoff: attempt=0 error=IO error: failed to lookup address information: nodename nor servname provided, or not known
2026-07-18T22:14:03.105Z INFO  chisel_cloud_bridge::handoff: attempt=1 delay=1s [handoff] connect_acp: retrying'
if _is_sandboxed_proxy_tls_failure "$rustls_fixture"; then ok "tls: rustls+OSStatus fixture detected"; else bad "tls: rustls+OSStatus fixture MISSED"; fi

# Positive: a different OSStatus code (the broader OSStatus -[0-9]+ pattern, not just -26276).
if _is_sandboxed_proxy_tls_failure 'ERROR rustls_platform_verifier::verification::apple: invalid peer certificate: Other(OtherError("OSStatus -26277: -26277"))'; then ok "tls: rustls+OSStatus -26277 detected"; else bad "tls: rustls+OSStatus -26277 MISSED"; fi

# Positive: corroborated pass — chisel_cloud_bridge + OSStatus without the rustls token on the
# matched scan (the same root cause surfaced through the chisel handoff log line).
if _is_sandboxed_proxy_tls_failure 'INFO  chisel_cloud_bridge::handoff: attempt=3 delay=4s [handoff] connect_acp: retrying
WARN  chisel: peer cert verify failed: OSStatus -26276'; then ok "tls: chisel+OSStatus corroborated detected"; else bad "tls: chisel+OSStatus corroborated MISSED"; fi

# Negative: the GENERIC "Connection error" devin prints to its caller. This is the whole point —
# the bare surfaced message must NOT be matched (it could mean anything); only the devin-log
# signature is recognizable.
generic_connection=(
  'Error: Agent error: Connection error, send a message to continue retrying'
  'Connection error, send a message to continue retrying'
  'Connection error'
  'connection refused'
)
for c in "${generic_connection[@]}"; do
  if _is_sandboxed_proxy_tls_failure "$c"; then bad "tls: generic connection message FALSE-POSITIVE: '$c'"; else ok "tls: generic connection message not matched: '$c'"; fi
done

# Negative: ordinary task/test failures and unrelated network errors (already covered by
# _is_transport_failure). The new detector must not fire on these — no behavior change.
non_tls=(
  'npm test failed'
  'Tests failed'
  'max-turns reached'
  'some normal task error'
  'HTTP 429: rate limit hit'
  'connection timed out'
  'curl: (6) Could not resolve host: openrouter.ai'
  'model_not_found: unknown model'
  'Authentication required: 401'
  'the rustls crate is used by devin for TLS'                # prose mention of rustls, no OSStatus
  'OSStatus is an Apple Security framework error code'      # prose mention of OSStatus, no rustls/chisel
  'chisel is a tool for tunneling'                          # prose mention of chisel, no OSStatus
)
for c in "${non_tls[@]}"; do
  if _is_sandboxed_proxy_tls_failure "$c"; then bad "tls: non-TLS FALSE-POSITIVE: '$c'"; else ok "tls: non-TLS not matched: '$c'"; fi
done

# Negative: empty text.
if _is_sandboxed_proxy_tls_failure ""; then bad "tls: empty text FALSE-POSITIVE"; else ok "tls: empty text not matched"; fi

# --- Scenario 2: _devin_sandboxed_proxy_tls_hint surfaces the hint from devin's own CLI log. ---
# Build a fake HOME with a devin CLI log dir + a newest log carrying the signature at its tail.
mkdir -p "$HOME/.local/share/devin/cli/logs"
# An older log file (must NOT be scanned when a newer one exists — avoids stale matches).
printf '%s\n' 'ERROR rustls_platform_verifier::verification::apple: OSStatus -9843 (stale, older session)' \
  > "$HOME/.local/share/devin/cli/logs/devin_old.log"
# sleep 1 for deterministic mtime ordering on macOS (1s mtime granularity on HFS+; APFS is finer
# but `ls -t` ties are still possible sub-second). Guarantees the newest log sorts strictly newer.
sleep 1
# The newest log: the rustls/chisel retry storm at the tail (within the default 300-line scan).
{
  for i in $(seq 1 20); do printf '%s\n' "2026-07-18T22:13:0${i}Z INFO  devin: starting up (line $i)"; done
  printf '%s\n' "$rustls_fixture"
} > "$HOME/.local/share/devin/cli/logs/devin_newest.log"

hint_out="$(_devin_sandboxed_proxy_tls_hint 2>&1)"
if [ -n "$hint_out" ]; then ok "hint: emitted on signature in newest devin log"; else bad "hint: NOT emitted on signature"; fi
if printf '%s' "$hint_out" | grep -q 'devin TLS handshake failed against a local proxy'; then ok "hint: names the cause"; else bad "hint: missing cause line"; fi
if printf '%s' "$hint_out" | grep -q 'OSStatus -26276'; then ok "hint: carries the recognized OSStatus code"; else bad "hint: missing OSStatus code"; fi
if printf '%s' "$hint_out" | grep -qi 'sandbox'; then ok "hint: names the fix (sandbox/proxy disabled)"; else bad "hint: missing fix"; fi
# Must NOT surface the stale older-session code.
if printf '%s' "$hint_out" | grep -q 'OSStatus -9843'; then bad "hint: FALSE-POSITIVE on stale older log (scanned the wrong file)"; else ok "hint: did not match stale older log"; fi

# --- Scenario 2b: hint is silent when the devin log signature is absent. ---
rm -f "$HOME/.local/share/devin/cli/logs"/devin_*.log
printf '%s\n' '2026-07-18T22:15:00Z INFO  devin: normal run, no TLS error' \
  > "$HOME/.local/share/devin/cli/logs/devin_clean.log"
silent_out="$(_devin_sandboxed_proxy_tls_hint 2>&1)"
if [ -n "$silent_out" ]; then bad "hint: FALSE-POSITIVE on clean devin log"; else ok "hint: silent on clean devin log"; fi

# --- Scenario 2c: hint is silent when the devin log dir does not exist. ---
rm -rf "$HOME/.local/share/devin"
silent_out="$(_devin_sandboxed_proxy_tls_hint 2>&1)"
if [ -n "$silent_out" ]; then bad "hint: FALSE-POSITIVE with no devin log dir"; else ok "hint: silent with no devin log dir"; fi

# --- Scenario 3: _devin_job_tls_hint gates on provider + terminal state + dedup. ---
# Re-create a devin log with the signature for the job-path scenarios.
mkdir -p "$HOME/.local/share/devin/cli/logs"
printf '%s\n' "$rustls_fixture" > "$HOME/.local/share/devin/cli/logs/devin_newest.log"
mkdir -p "$OSRC_HOME/jobs"

# 3a: failed devin job, hint not already in shown text -> emits.
jid="job-devin-failed"
jd="$OSRC_HOME/jobs/$jid"; mkdir -p "$jd"
printf '{"provider":"devin","verb":"run","model":"glm-5.2"}' > "$jd/meta.json"
echo failed > "$jd/status"
job_hint="$(_devin_job_tls_hint "$jid" 'Error: Agent error: Connection error' 2>&1)"
if [ -n "$job_hint" ]; then ok "job_hint: emits for failed devin job without hint in shown text"; else bad "job_hint: did NOT emit for failed devin job"; fi

# 3b: hint already in shown text -> silent (no double-print).
job_hint_dup="$(_devin_job_tls_hint "$jid" 'devin TLS handshake failed against a local proxy in your shell (rustls cert verify: OSStatus -26276).' 2>&1)"
if [ -n "$job_hint_dup" ]; then bad "job_hint: DOUBLE-PRINTED when hint already in shown text"; else ok "job_hint: silent when hint already in shown text"; fi

# 3c: non-devin provider -> silent (no false hint for a cc/codex job).
jid2="job-cc-failed"; jd2="$OSRC_HOME/jobs/$jid2"; mkdir -p "$jd2"
printf '{"provider":"cc","verb":"run","model":"glm-5.2"}' > "$jd2/meta.json"
echo failed > "$jd2/status"
job_hint_cc="$(_devin_job_tls_hint "$jid2" 'HTTP 429 rate limit' 2>&1)"
if [ -n "$job_hint_cc" ]; then bad "job_hint: FALSE-POSITIVE for non-devin (cc) job"; else ok "job_hint: silent for non-devin (cc) job"; fi

# 3d: devin job NOT in a terminal-failed state -> silent (running/done don't get the hint).
jid3="job-devin-running"; jd3="$OSRC_HOME/jobs/$jid3"; mkdir -p "$jd3"
printf '{"provider":"devin","verb":"run","model":"glm-5.2"}' > "$jd3/meta.json"
echo running > "$jd3/status"
job_hint_run="$(_devin_job_tls_hint "$jid3" 'some progress' 2>&1)"
if [ -n "$job_hint_run" ]; then bad "job_hint: FALSE-POSITIVE for non-terminal (running) devin job"; else ok "job_hint: silent for non-terminal devin job"; fi

# 3e: nonexistent job -> silent (no crash).
job_hint_none="$(_devin_job_tls_hint "no-such-job" 'whatever' 2>&1)"
if [ -n "$job_hint_none" ]; then bad "job_hint: emitted for nonexistent job"; else ok "job_hint: silent for nonexistent job"; fi

# --- Scenario 3f: cmd_result/cmd_logs preserve exit 0 on a successful print (regression guard).
# The diagnostics helper must NOT change result/logs' return code: a no-match helper exits 1, and
# if it became the function's return code, `result`/`logs` would return non-zero on every successful
# print. Re-emit-on-match must also leave the exit code at 0.
# (a) devin job WITHOUT the TLS signature in devin's log -> hint silent, exit 0.
rm -f "$HOME/.local/share/devin/cli/logs"/devin_*.log
printf '%s\n' 'INFO  devin: normal run, no TLS error' > "$HOME/.local/share/devin/cli/logs/devin_clean.log"
jid_clean="job-devin-clean"; jd_clean="$OSRC_HOME/jobs/$jid_clean"; mkdir -p "$jd_clean"
printf '{"provider":"devin","verb":"run","model":"glm-5.2"}' > "$jd_clean/meta.json"
echo done > "$jd_clean/status"
printf 'all good, task complete\n' > "$jd_clean/last.txt"
printf 'all good, task complete\n' > "$jd_clean/out.log"
cmd_result "$jid_clean" >/dev/null 2>&1; rc_result=$?
if [ "$rc_result" -eq 0 ]; then ok "cmd_result: exit 0 on successful print (no TLS match)"; else bad "cmd_result: exit $rc_result (regression: helper exit leaked)"; fi
cmd_logs "$jid_clean" >/dev/null 2>&1; rc_logs=$?
if [ "$rc_logs" -eq 0 ]; then ok "cmd_logs: exit 0 on successful print (no TLS match)"; else bad "cmd_logs: exit $rc_logs (regression: helper exit leaked)"; fi

# (b) devin job WITH the TLS signature -> hint emitted to stderr, exit STILL 0.
printf '%s\n' "$rustls_fixture" > "$HOME/.local/share/devin/cli/logs/devin_newest.log"
jid_sig="job-devin-sig"; jd_sig="$OSRC_HOME/jobs/$jid_sig"; mkdir -p "$jd_sig"
printf '{"provider":"devin","verb":"run","model":"glm-5.2"}' > "$jd_sig/meta.json"
echo failed > "$jd_sig/status"
printf 'Error: Agent error: Connection error\n' > "$jd_sig/last.txt"
printf 'Error: Agent error: Connection error\n' > "$jd_sig/out.log"
sig_out="$(cmd_result "$jid_sig" 2>/tmp/rr_sig 1>/dev/null)"; rc_sig=$?
sig_err="$(cat /tmp/rr_sig 2>/dev/null)"; rm -f /tmp/rr_sig
if [ "$rc_sig" -eq 0 ]; then ok "cmd_result: exit 0 even when hint is emitted"; else bad "cmd_result: exit $rc_sig when hint emitted (regression)"; fi
if printf '%s' "$sig_err" | grep -q 'devin TLS handshake failed'; then ok "cmd_result: hint emitted to stderr on signature"; else bad "cmd_result: hint NOT emitted on signature"; fi
sig_logs_out="$(cmd_logs "$jid_sig" 2>/tmp/rl_sig 1>/dev/null)"; rc_sigl=$?
sig_logs_err="$(cat /tmp/rl_sig 2>/dev/null)"; rm -f /tmp/rl_sig
if [ "$rc_sigl" -eq 0 ]; then ok "cmd_logs: exit 0 even when hint is emitted"; else bad "cmd_logs: exit $rc_sigl when hint emitted (regression)"; fi
if printf '%s' "$sig_logs_err" | grep -q 'devin TLS handshake failed'; then ok "cmd_logs: hint emitted to stderr on signature"; else bad "cmd_logs: hint NOT emitted on signature"; fi

# (c) non-devin (cc) job -> hint silent, exit 0.
jid_cc="job-cc-clean"; jd_cc="$OSRC_HOME/jobs/$jid_cc"; mkdir -p "$jd_cc"
printf '{"provider":"cc","verb":"run","model":"glm-5.2"}' > "$jd_cc/meta.json"
echo done > "$jd_cc/status"
printf 'result text\n' > "$jd_cc/last.txt"
cc_err="$(cmd_result "$jid_cc" 2>&1 >/dev/null)"; rc_cc=$?
if [ "$rc_cc" -eq 0 ] && [ -z "$cc_err" ]; then ok "cmd_result: non-devin job exit 0, no hint"; else bad "cmd_result: non-devin job rc=$rc_cc err='$cc_err'"; fi

# --- Scenario 4: regression — _is_transport_failure classifications are NOT affected. ---
# The new diagnostics must not change existing transport-vs-task classification. Re-assert a few
# canonical cases from test_escalation_classify.sh stay classified exactly as before.
if _is_transport_failure 'HTTP 429: rate limit hit' 1; then ok "regression: 429 still transport"; else bad "regression: 429 no longer transport"; fi
if _is_transport_failure 'connection refused' 1; then ok "regression: connection refused still transport"; else bad "regression: connection refused no longer transport"; fi
if _is_transport_failure 'curl: (6) Could not resolve host: openrouter.ai' 1; then ok "regression: could not resolve host still transport"; else bad "regression: could not resolve host no longer transport"; fi
if _is_transport_failure 'npm test failed' 1; then bad "regression: npm test falsely classified transport"; else ok "regression: npm test still NOT transport"; fi
if _is_transport_failure 'max-turns reached' 1; then bad "regression: max-turns falsely classified transport"; else ok "regression: max-turns still NOT transport"; fi
# The devin-log signature itself is NOT a transport failure (it is a diagnostics signal, not a
# retry trigger) — asserting this keeps the diagnostics-only contract honest.
if _is_transport_failure "$rustls_fixture" 1; then bad "regression: rustls signature leaked into _is_transport_failure (would change retry behavior)"; else ok "regression: rustls signature stays out of _is_transport_failure"; fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
