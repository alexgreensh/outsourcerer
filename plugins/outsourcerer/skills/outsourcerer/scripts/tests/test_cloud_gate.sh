#!/usr/bin/env bash
# test_cloud_gate.sh — cloud-disclosure + secret-scan gate conformance.
# Loads the gate primitives from outsourcerer.sh and exercises them OFFLINE (no real
# delegation). Mirrors the scripts/tests/ shim-test style. Run: bash test_cloud_gate.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
if [ ! -f "$SRC" ]; then echo FAIL: cannot find "$SRC"; exit 1; fi

# Load the script's functions. main "$@" runs with no args (prints help, returns 0);
# all gate functions are then defined in this shell. set -u is inherited from the
# sourced file, so keep every expansion default-safe.
. "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok()  { echo PASS: $1; pass=$((pass+1)); }
bad() { echo FAIL: $1; fail=$((fail+1)); }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

TMP="$(mktemp -d)"

# --- Scenario 1: local lanes classified non-cloud; skip the gate entirely. ---
if ! _is_cloud_lane "local" >/dev/null 2>&1; then ok "local lane classified non-cloud"; else bad "local lane mis-classified as cloud"; fi
if ! _is_cloud_lane "ollama" >/dev/null 2>&1 && ! _is_cloud_lane "lmstudio" >/dev/null 2>&1; then ok "ollama/lmstudio classified non-cloud"; else bad "ollama/lmstudio mis-classified as cloud"; fi
out="$( ( cd "$TMP"; unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; _cloud_disclose "local" "llama3" "do thing" ) 2>&1 )"
[ $? -eq 0 ] && ok "non-cloud _cloud_disclose returns 0" || bad "non-cloud _cloud_disclose nonzero"
echo "$out" | grep -qi 'CLOUD' && bad "non-cloud lane printed a cloud disclosure" || ok "non-cloud lane prints no disclosure"

# --- Scenario 2: cloud lane, non-interactive, no ack => fail-closed REFUSE. ---
out="$( ( cd "$TMP"; unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; _cloud_disclose "ccor" "gpt-4o" "summarize repo" ) </dev/null 2>&1 )"; rc=$?
[ $rc -ne 0 ] && ok "cloud no-ack non-interactive REFUSES (rc=$rc)" || bad "cloud no-ack non-interactive proceeded (rc=$rc)"
echo "$out" | grep -qi 'CLOUD GATE' && ok "refusal names CLOUD GATE" || bad "refusal missing CLOUD GATE marker"

# --- Scenario 3: cloud lane with OSRC_CLOUD_ACK=1 => proceeds + disclosure printed. ---
out="$( ( cd "$TMP"; unset OSRC_CLOUD_ACKED; OSRC_CLOUD_ACK=1; _cloud_disclose "ccor" "gpt-4o" "summarize repo" ) 2>&1 )"; rc=$?
[ $rc -eq 0 ] && ok "cloud with OSRC_CLOUD_ACK=1 proceeds (rc=0)" || bad "cloud ack path failed (rc=$rc)"
echo "$out" | grep -q 'CLOUD DISCLOSURE' && ok "disclosure block printed" || bad "disclosure block missing"
echo "$out" | grep -q 'repo content LEAVES' && ok "disclosure states data leaves machine" || bad "disclosure omits data-leaves note"

# --- Scenario 4: a real .env in cwd scope => hard die with the path, ack or not. ---
mkdir -p "$TMP/envscope"
printf 'OPENROUTER_API_KEY=sk-XXXX\n' > "$TMP/envscope/.env"
out="$( ( cd "$TMP/envscope"; unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; OSRC_CLOUD_ACK=1; _cloud_disclose "ccor" "gpt-4o" "task" ) 2>&1 )"; rc=$?
[ $rc -ne 0 ] && ok "real .env in scope hard-dies (rc=$rc)" || bad "real .env in scope did NOT die"
echo "$out" | grep -q "$TMP/envscope/.env" && ok "die names the credential path" || bad "die omitted credential path"

# --- Scenario 4b: a NESTED credential file (not at PWD root) is also caught by the deep scan. ---
mkdir -p "$TMP/deepscope/services/prod"
printf 'AWS_SECRET_ACCESS_KEY=xxxx\n' > "$TMP/deepscope/services/prod/.env"
out="$( ( cd "$TMP/deepscope"; unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; OSRC_CLOUD_ACK=1; _cloud_disclose "ccor" "gpt-4o" "task" ) 2>&1 )"; rc=$?
[ $rc -ne 0 ] && ok "nested services/prod/.env hard-dies" || bad "nested .env NOT caught (deep scan failed)"
echo "$out" | grep -q "deepscope/services/prod/.env" && ok "die names the nested credential path" || bad "die omitted nested path"

# --- Scenario 4c (CRITICAL): an inherited OSRC_CLOUD_ACKED must NOT skip the secret scan. ---
out="$( ( cd "$TMP/deepscope"; unset OSRC_CLOUD_ACK; export OSRC_CLOUD_ACKED=1; _cloud_disclose "ccor" "gpt-4o" "task" ) 2>&1 )"; rc=$?
[ $rc -ne 0 ] && ok "inherited OSRC_CLOUD_ACKED still runs the credential hard-block" || bad "ACKED bypassed the secret scan (CRITICAL regression)"

# The deliberately-planted cred fixtures must not leak into later 'clean scope' scenarios via the deep scan.
rm -rf "$TMP/envscope" "$TMP/deepscope"

# --- Scenario 5: ':free' route disclosure states may-train. ---
out="$( ( cd "$TMP"; unset OSRC_CLOUD_ACKED; OSRC_CLOUD_ACK=1; _cloud_disclose "ccor" "google/gemini-flash-1.5:free" "task" ) 2>&1 )"; rc=$?
[ $rc -eq 0 ] && ok "':free' route with ack proceeds" || bad "':free' route ack failed"
echo "$out" | grep -qi 'MAY TRAIN' && ok "':free' disclosure states may-train" || bad "':free' disclosure missing may-train note"

# --- Scenario 6: idempotency — acking once sets OSRC_CLOUD_ACKED for the process. ---
out="$( ( cd "$TMP"; unset OSRC_CLOUD_ACKED; OSRC_CLOUD_ACK=1
          _cloud_disclose "ccor" "gpt-4o" "t1"
          [ "${OSRC_CLOUD_ACKED:-0}" = "1" ] && echo ACKED_SET
          _cloud_disclose "ccor" "gpt-4o" "t2"
        ) 2>&1 )"; rc=$?
[ $rc -eq 0 ] && ok "second cloud call in-process passes after ack" || bad "second call re-prompted/failed"
echo "$out" | grep -q 'ACKED_SET' && ok "OSRC_CLOUD_ACKED set after first ack" || bad "OSRC_CLOUD_ACKED not set"

# --- Scenario 7: wire-in point present in route_delegate. ---
if grep -q '_cloud_disclose "$disp"' "$SRC"; then ok "route_delegate wires the gate after lane resolution"; else bad "gate not wired into route_delegate"; fi
if grep -q 'OSRC_CLOUD_ACKED' "$SRC"; then ok "OSRC_CLOUD_ACKED guard present"; else bad "OSRC_CLOUD_ACKED guard missing"; fi

# --- Scenario 8: --cloud-ack is a real leading flag, consumed (not leaked), and a task PROMPT
#     containing the literal "--cloud-ack" must NOT set the ack (no string-match bypass). ---
# NOTE: call _consume_flags WITHOUT a subshell so the vars it sets are visible here.
unset OSRC_CLOUD_ACK; _consume_flags -m glm --cloud-ack "do a thing"
[ "${OSRC_CLOUD_ACK:-0}" = "1" ] && ok "leading --cloud-ack flag sets the ack" || bad "leading --cloud-ack did not set ack"
case " ${REST[*]:-} " in *' --cloud-ack '*) bad "--cloud-ack leaked into REST/prompt" ;; *) ok "--cloud-ack consumed, not left in REST" ;; esac
# a prompt that merely mentions --cloud-ack (flag appears AFTER the positional task) must not ack
unset OSRC_CLOUD_ACK; _consume_flags -m glm "please pass --cloud-ack somewhere"
[ "${OSRC_CLOUD_ACK:-0}" = "1" ] && bad "task-prompt mention of --cloud-ack bypassed the gate" || ok "task-prompt mention of --cloud-ack does NOT ack (no bypass)"
if grep -q 'case " ${ORIG\[\*\]} " in \*.*--cloud-ack' "$SRC"; then bad "dead ORIG string-match for --cloud-ack still present"; else ok "ORIG string-match bypass removed"; fi

# --- Scenario 9: secret scan surfaces a COUNT, never the matched secret text. ---
( cd "$TMP" && WITH_SPEC="" _secret_scan "here is a key sk-FAKEfixture0notarealkey and OPENROUTER_API_KEY=x" >/dev/null 2>&1; echo "${OSRC_SECRET_HIT_COUNT:-0}" ) > "$TMP/cnt"
[ "$(cat "$TMP/cnt")" -ge 1 ] 2>/dev/null && ok "secret scan sets a positive hit count" || bad "secret hit count not set"
out="$( ( cd "$TMP"; unset OSRC_CLOUD_ACKED; OSRC_CLOUD_ACK=1; _cloud_disclose "ccor" "gpt-4o" "leak sk-FAKEfixture0notarealkey here" ) 2>&1 )"
echo "$out" | grep -q 'sk-FAKEfixture0notarealkey' && bad "raw secret value printed to stderr" || ok "raw secret value NOT printed (redacted)"
echo "$out" | grep -qi 'values redacted' && ok "disclosure states values redacted" || bad "redaction note missing"

# --- Scenario 10: bg/fanout cloud gate acquired at launch, not in the detached (no-TTY) child. ---
PROVIDER=devin
( unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; _bg_cloud_preack run -m glm "task" </dev/null >/dev/null 2>&1 )
[ $? -ne 0 ] && ok "cloud bg preack REFUSES non-interactive without ack" || bad "cloud bg preack proceeded without ack"
( export OSRC_CLOUD_ACK=1; _bg_cloud_preack run -m glm "task" </dev/null >/dev/null 2>&1 )
[ $? -eq 0 ] && ok "cloud bg preack passes with OSRC_CLOUD_ACK=1" || bad "cloud bg preack blocked despite ack"
( unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; PROVIDER=local; _bg_cloud_preack run -m ollama:llama3 "task" </dev/null >/dev/null 2>&1 )
[ $? -eq 0 ] && ok "local-lane bg preack exempt (no ack needed)" || bad "local-lane bg preack wrongly refused"
if grep -q '_bg_cloud_preack "\$@"' "$SRC"; then ok "preack wired into _bg_launch"; else bad "preack not wired into _bg_launch"; fi

# --- Scenario 11: black-box cmd_bg -- a refused cloud gate must ABORT the whole command
#     (not fake-success inside the id=$(...) subshell), and --cloud-ack must actually let it through. ---
# Stub _bg_launch so we never spawn a real detached job; it records that it was reached.
_bg_launch() { echo REACHED_LAUNCH > "$TMP/launched"; echo "stubid-123"; }
PROVIDER=devin
rm -f "$TMP/launched"
( cd "$TMP"; unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; cmd_bg run -m glm "task" </dev/null >/dev/null 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && ok "cmd_bg refused cloud gate returns nonzero (no fake success)" || bad "cmd_bg exited 0 despite refusal"
[ ! -f "$TMP/launched" ] && ok "cmd_bg did NOT reach _bg_launch after refusal" || bad "cmd_bg launched a job despite refusal"
rm -f "$TMP/launched"
out="$( cd "$TMP"; unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; cmd_bg run --cloud-ack -m glm "task" </dev/null 2>/dev/null )"; rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$TMP/launched" ] && printf '%s' "$out" | grep -q 'stubid-123'; } && ok "cmd_bg --cloud-ack proceeds to launch and prints the job id" || bad "cmd_bg --cloud-ack did not launch (rc=$rc)"

# --- Scenario 12: _bg_cloud_preack honors --cloud-ack only among LEADING flags, never a
#     positional task that merely equals "--cloud-ack" (passed after `--`). ---
PROVIDER=devin
( unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; _bg_cloud_preack run -m glm --cloud-ack "task" </dev/null >/dev/null 2>&1 )
[ $? -eq 0 ] && ok "leading --cloud-ack still acks the bg/fanout preack" || bad "leading --cloud-ack no longer acks"
( unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; _bg_cloud_preack run -m glm -- --cloud-ack </dev/null >/dev/null 2>&1 )
[ $? -ne 0 ] && ok "a task literally '--cloud-ack' after '--' does NOT self-ack (still refuses)" || bad "positional --cloud-ack after -- bypassed the gate"
# the -m value must not be mistaken for the task, and a normal cloud job still refuses without ack
( unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; _bg_cloud_preack run -m glm "just do the thing" </dev/null >/dev/null 2>&1 )
[ $? -ne 0 ] && ok "ordinary cloud bg job still refuses without ack" || bad "cloud job proceeded without ack"

# --- Scenario 13: route_delegate must call _cloud_disclose UNCONDITIONALLY.
#     The ack-skip lives INSIDE the function (after the scan); guarding the CALL let an inherited
#     OSRC_CLOUD_ACKED=1 bypass the credential hard-block entirely. ---
if grep -q '_cloud_disclose "$disp"' "$SRC"; then ok "route_delegate calls _cloud_disclose"; else bad "_cloud_disclose call missing from route_delegate"; fi
ctx="$(grep -B2 '_cloud_disclose "\$disp"' "$SRC")"
echo "$ctx" | grep -q 'OSRC_CLOUD_ACKED.*!=.*1' && bad "_cloud_disclose STILL guarded by an ACKED conditional at the call site (bypass)" || ok "no ACKED guard wrapping the _cloud_disclose call"

# --- Scenario 14: a bogus OSRC_SECRET_SCAN_DEPTH must NOT fail the deep scan open. ---
mkdir -p "$TMP/bogusdepth/nested"
printf 'OPENROUTER_API_KEY=sk-XXXX\n' > "$TMP/bogusdepth/nested/.env"
out="$( ( cd "$TMP/bogusdepth"; unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; OSRC_CLOUD_ACK=1 OSRC_SECRET_SCAN_DEPTH=bogus _cloud_disclose "ccor" "gpt-4o" "task" ) 2>&1 )"; rc=$?
[ $rc -ne 0 ] && ok "bogus scan depth still hard-dies on nested .env (no fail-open)" || bad "bogus scan depth FAILED OPEN"
rm -rf "$TMP/bogusdepth"

# --- Scenario 14b: a routine unreadable (mode-000) subdir is permission NOISE, not a scan
#     failure -- the deep scan must tolerate it and PROCEED (same-privilege), not fail-closed. ---
mkdir -p "$TMP/permnoise/src" "$TMP/permnoise/locked"; echo "code" > "$TMP/permnoise/src/a.py"; chmod 000 "$TMP/permnoise/locked"
( cd "$TMP/permnoise"; unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; OSRC_CLOUD_ACK=1 _cloud_disclose "ccor" "gpt-4o" "task" ) >/dev/null 2>&1; rc=$?
chmod 755 "$TMP/permnoise/locked" 2>/dev/null
[ $rc -eq 0 ] && ok "mode-000 subdir tolerated as permission noise (no wrong fail-closed)" || bad "routine unreadable dir wrongly refused a normal repo"
rm -rf "$TMP/permnoise"

# --- Scenario 15: static presence of the fail-loud guards. ---
grep -q 'supervisor not executable' "$SRC" && ok "_bg_launch validates SCRIPT_PATH is executable" || bad "SCRIPT_PATH executable check missing"
grep -q 'capture dir not writable' "$SRC" && ok "delegate_codex refuses on non-writable capture dir" || bad "capdir writable check missing"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
