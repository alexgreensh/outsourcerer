#!/usr/bin/env bash
# Regression guard for the free Devin lane: stale CLI processes must not wedge it,
# paid-tier quota text must not mark it down, and every liveness request is bounded
# without relying on a platform-specific timeout executable.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

TEST_ROOT="$(mktemp -d "${TMPDIR:-/var/tmp}/osrc-devin-guard.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
export OSRC_HOME="$TEST_ROOT/state"
export OSRC_JOBS="$OSRC_HOME/jobs"
mkdir -p "$OSRC_JOBS" "$TEST_ROOT/bin"

# Load only the functions under test. Production dependencies are stubbed where
# the test does not exercise them directly.
_mkdir_private() { mkdir -p "$1"; }
_kill_tree() { kill -TERM "$1" 2>/dev/null || true; }
eval "$(sed -n '/^_timeout() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^_devin_elapsed_secs() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^_devin_pid_descends_from() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^_devin_pid_owned_by_live_job() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^_devin_process_rows() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^_devin_orphan_pids() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^_devin_zombie_preflight() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^_devin_probe_classify() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^_devin_free_probe() {/,/^}/p' "$SRC")"

# A real fake executable exercises the bash-native bound and exact glm-5-2 call.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case " $* " in' \
  '  *" --model glm-5-2 "*) printf '\''PONG\n'\''; exit 0 ;;' \
  '  *) exit 9 ;;' \
  'esac' > "$TEST_ROOT/bin/devin"
chmod +x "$TEST_ROOT/bin/devin"
PATH="$TEST_ROOT/bin:$PATH"
probe_out="$(OSRC_DEVIN_PROBE_SECS=2 _devin_free_probe)"; probe_rc=$?
probe_state="$(_devin_probe_classify "$probe_rc" "$probe_out")"
[ "$probe_state" = "up" ] && ok "bounded glm-5-2 probe response classifies the free lane UP" \
  || bad "probe classified '$probe_state' (rc=$probe_rc, output=$probe_out), expected up"

# The image lane sends its prompt over stdin. Bash normally redirects an async
# command's stdin to /dev/null, so the native bound must preserve fd 0 explicitly.
stdin_out="$(printf 'image prompt' | _timeout 2 sh -c 'IFS= read -r value; printf "%s" "$value"')"
[ "$stdin_out" = "image prompt" ] \
  && ok "bash-native bound preserves piped stdin for Codex prompt consumers" \
  || bad "bash-native bound dropped piped stdin (got: $stdin_out)"

# Deterministic process-table input: an old devin process with no live job owner
# must be identified. The detector only lists it here, so the test never signals $$.
printf '%s %s %s %s %s\n' "$$" "1" "3600" "devin" "devin --model glm-5-2 -p task" > "$TEST_ROOT/ps.rows"
orphans="$(OSRC_DEVIN_PS_FILE="$TEST_ROOT/ps.rows" OSRC_DEVIN_ZOMBIE_MINS=30 _devin_orphan_pids)"
printf '%s\n' "$orphans" | awk -v p="$$" '$1 == p { found=1 } END { exit !found }' \
  && ok "orphan detection identifies an aged unowned devin PID" \
  || bad "orphan detection missed unowned PID $$ (rows: $orphans)"
mkdir -p "$OSRC_JOBS/live-job"
printf '%s\n' "$$" > "$OSRC_JOBS/live-job/pid"
owned_rows="$(OSRC_DEVIN_PS_FILE="$TEST_ROOT/ps.rows" OSRC_DEVIN_ZOMBIE_MINS=30 _devin_orphan_pids)"
[ -z "$owned_rows" ] \
  && ok "an aged devin PID owned by a live outsourcerer job is preserved" \
  || bad "owned PID $$ was falsely classified as orphaned (rows: $owned_rows)"

# Exercise the reap logic with a fake process table and mocked killer. No live
# Devin process or real PID is started or signaled by this unit test.
rm -rf "$OSRC_JOBS/live-job"
printf '%s %s %s %s %s\n' 424242 1 3600 devin 'devin --model glm-5-2 -p task' > "$TEST_ROOT/ps.rows"
_kill_tree(){ printf '%s\n' "$1" >> "$TEST_ROOT/killed-pids"; }
OSRC_DEVIN_PS_FILE="$TEST_ROOT/ps.rows" OSRC_DEVIN_ZOMBIE_MINS=30 _devin_zombie_preflight 2>/dev/null
[ "$(cat "$TEST_ROOT/killed-pids" 2>/dev/null)" = 424242 ] \
  && ok "zombie preflight reaps only the mocked old unowned Devin model PID" \
  || bad "zombie preflight did not invoke bounded cleanup for the mocked orphan"

# The canonical paid-ACU refusal is not a free-lane-down verdict.
quota_text='Your weekly usage quota has been exhausted'
quota_state="$(_devin_probe_classify 1 "$quota_text")"
[ "$quota_state" = "paid-tier-exhausted" ] \
  && ok "paid weekly quota exhaustion does not classify free GLM as down" \
  || bad "paid quota classified '$quota_state', expected paid-tier-exhausted"

# The persisted-job classifier must make the same distinction. Historically it
# converted this exact paid message into RETRY-DIFFERENT-LANE/quota-exhausted
# for every Devin model, including free GLM.
quota_job="$OSRC_JOBS/paid-text-on-free-glm"
mkdir -p "$quota_job"
printf '%s\n' '{"id":"paid-text-on-free-glm","lane":"dv","provider":"devin","model":"glm-5.2","cwd":""}' > "$quota_job/meta.json"
printf '%s\n' failed > "$quota_job/status"
printf '%s\n' 1 > "$quota_job/exit"
printf '%s\n' 'Error: Your weekly usage quota has been exhausted' > "$quota_job/out.log"
: > "$quota_job/last.txt"
classify_out="$(OSRC_HOME="$OSRC_HOME" OSRC_JOBS="$OSRC_JOBS" bash "$SRC" classify paid-text-on-free-glm 2>/dev/null)"
case "$classify_out" in
  RETRY-DIFFERENT-LANE*) bad "post-hoc classifier marked free GLM quota-exhausted ($classify_out)" ;;
  *) ok "post-hoc classifier does not gate free GLM on paid quota text" ;;
esac

grep -q '_devin_guard_before_delegation "$MODEL"' "$SRC" \
  && ok "foreground and continue delegations invoke the Devin guard" \
  || bad "Devin delegation path does not invoke the guard"
[ "$(grep -c '_devin_guard_before_delegation "\$MODEL"' "$SRC")" -ge 4 ] \
  && ok "the guard covers one-shot, continue, and both interactive session launch paths" \
  || bad "not every Devin launch path is guarded"
grep -q '^  _devin_zombie_preflight$' "$SRC" \
  && ok "doctor invokes the zombie reap preflight" \
  || bad "doctor does not invoke the zombie reap preflight"
grep -q 'paid Devin models exhausted; free tier (glm-5-2, swe-1-7) still available' "$SRC" \
  && ok "paid-model failures explicitly preserve the free GLM/SWE tier" \
  || bad "paid quota failure still presents as blanket Devin exhaustion"

# The implementation must be bash-native even on hosts where coreutils is installed.
# Match executable invocations, including a command at the start of a line or after a pipe,
# while allowing the internal _timeout helper and prose that merely says "timeout".
if grep -Eq '(^|[;&|[:space:]])g?timeout[[:space:]]+[0-9]' "$SRC"; then
  bad "outsourcerer still invokes an external timeout/gtimeout binary"
else
  ok "no external timeout/gtimeout binary is used"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
