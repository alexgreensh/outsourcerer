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

# Deterministic process-table input: an old devin process with no live job owner
# must be identified. The detector only lists it here, so the test never signals $$.
printf '%s %s %s %s %s\n' "$$" "1" "3600" "devin" "devin --model glm-5-2 -p task" > "$TEST_ROOT/ps.rows"
orphans="$(OSRC_DEVIN_PS_FILE="$TEST_ROOT/ps.rows" OSRC_DEVIN_ZOMBIE_MINS=30 _devin_orphan_pids)"
printf '%s\n' "$orphans" | awk -v p="$$" '$1 == p { found=1 } END { exit !found }' \
  && ok "orphan detection identifies an aged unowned devin PID" \
  || bad "orphan detection missed unowned PID $$ (rows: $orphans)"

# The canonical paid-ACU refusal is not a free-lane-down verdict.
quota_text='Your weekly usage quota has been exhausted'
quota_state="$(_devin_probe_classify 1 "$quota_text")"
[ "$quota_state" = "paid-tier-exhausted" ] \
  && ok "paid weekly quota exhaustion does not classify free GLM as down" \
  || bad "paid quota classified '$quota_state', expected paid-tier-exhausted"

# The implementation must be bash-native even on hosts where coreutils is installed.
if grep -Eq 'command -v (g?timeout)|then (g?timeout)[[:space:]]' "$SRC"; then
  bad "outsourcerer still invokes an external timeout/gtimeout binary"
else
  ok "no external timeout/gtimeout binary is used"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
