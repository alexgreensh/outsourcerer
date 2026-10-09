#!/usr/bin/env bash
# test_session_probe_sigpipe.sh — the lane capability probes and _fleet_name_model must take the
# RIGHT branch when the producer outgrows the pipe buffer.
#
# The engine runs under `set -uo pipefail`. A producer feeding `grep -q` in a pipeline gets
# SIGPIPE (rc 141) when grep exits on its first match while more than the pipe buffer
# (~16-64KB) is still unwritten, and pipefail turns the pipeline non-zero. The probe sites
# consume that rc directly (`|| _session_launch_error`, `|| continue`), so an oversized but
# perfectly good input would take the FAILURE branch: an interactive lane launch would be
# refused, and a valid fleet name reply discarded. These cases feed >128KB producers (with every needed
# pattern present) through the real functions and assert the success branch.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
export HOME="$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Clear argv before sourcing: the engine dispatches on "$@".
set --
. "$SRC" >/dev/null 2>&1
# Re-arm AFTER sourcing: the engine installs its own EXIT trap, which replaces this one.
trap cleanup EXIT

for fn in _session_probe_help _session_launch_droid _session_launch_cursor _session_launch_hermes _session_launch_cline _fleet_name_model; do
  type "$fn" >/dev/null 2>&1 || { echo "FAIL: $fn not defined"; exit 1; }
done

# >128KB so the producer provably outgrows any pipe buffer the OS may use (XNU grows pipes
# to ~64KB; GNU/Linux stays at 16KB), past the size where the race is deterministic.
_base="$(printf 'x%.0s' $(seq 1 300))"
_help_body=""
i=0
while [ "$i" -lt 400 ]; do _help_body="$_help_body$_base-$i-$_base-$_base-$_base
"; i=$((i+1)); done
# 400 lines x ~1250 chars = ~500KB per help text.
printf '%s' "$_help_body" > "$TMP/big.txt"
BYSZ="$(wc -c < "$TMP/big.txt" | tr -d ' ')"

# Stub CLI bin dir: every stub prints a >128KB --help whose FIRST line already carries the
# capability pattern (the early match is what makes grep -q close the pipe). The stubs must
# also satisfy `have <cli>` for every lane under test, so the case is machine-independent.
BIN="$TMP/bin"; mkdir -p "$BIN"
write_help_stub() {   # <name> <first-line-patterns...>
  local name="$1"; shift
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "$1" = "--help" ] || [ "$2" = "--help" ]; then\n'
    printf '  cat <<"HDR"\n'
    for pat in "$@"; do printf '%s\n' "$pat"; done
    printf 'HDR\n'
    printf '  cat "$0.help"\n'
    printf '  exit 0\nfi\nexit 0\n'
  } > "$BIN/$name"
  chmod +x "$BIN/$name"
  cp "$TMP/big.txt" "$BIN/$name.help"
}

# droid: three capability greps run against the SAME top-level help.
write_help_stub droid \
  "usage: droid [options] [prompt...]" \
  "  interactive mode is the default; start an interactive mode session with no args" \
  "  exec runs non-interactive, noninteractively, for scripts/automation" \
  "  --auto low|medium|high bounded interactive autonomy"
# cursor: interactive chat + one-shot distinction.
write_help_stub cursor-agent \
  "usage: cursor-agent [options]" \
  "  interactive terminal mode session; chat mode is the default; start chat mode" \
  "  --print runs one-shot non-interactive; -p non-interactive"
# hermes: top-level help advertises the chat subcommand + interactive/one-shot modes; the
# chat --help output advertises the REPL + model override. One stub, patterns in BOTH paths.
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "$1" = "chat" ] && [ "$2" = "--help" ]; then\n'
  printf '  cat <<"HDR"\n'
  printf 'usage: hermes chat [options]\n'
  printf '  REPL interactive chat mode\n'
  printf '  --model <id>   model override\n'
  printf 'HDR\n  cat "$0.chat"\n  exit 0\nfi\n'
  printf 'cat <<"HDR"\n'
  printf 'usage: hermes [options] [command]\n'
  printf '  chat    interactive chat session (chat is a command)\n'
  printf '  one-shot non-interactive exec mode\n'
  printf 'HDR\n  cat "$0.help"\nexit 0\n'
} > "$BIN/hermes"
chmod +x "$BIN/hermes"
cp "$TMP/big.txt" "$BIN/hermes.help"
{
  printf 'usage: hermes chat [options]\n'
  printf '  REPL interactive chat mode\n'
  printf '  --model <id>   model override\n'
  cat "$TMP/big.txt"
} > "$BIN/hermes.chat"
# cline: interactive REPL + headless distinction.
write_help_stub cline \
  "usage: cline [options]" \
  "  interactive repl; plan mode and act mode; chat" \
  "  --plan, --auto-approve, non-interactive, headless one-shot"

export PATH="$BIN:$PATH"
PROVIDER="droid"; PROVIDER_EXPLICIT=1; MODEL_EXPLICIT=0; EFFORT=""

# run_launch <fn> — run a launch function in one subshell and report both its rc and the
# SESSION_LAUNCH it set (read INSIDE the subshell: a subshell's globals do not survive it).
RUN_RC=0; RUN_OUT=""; RUN_LAUNCH=""
run_launch() {
  local s
  s="$( "$1"; local rc=$?; printf 'LAUNCH=%s' "${SESSION_LAUNCH[*]:-none}"; exit "$rc" )"
  RUN_RC=$?; RUN_OUT="${s%%LAUNCH=*}"; RUN_LAUNCH="${s##*LAUNCH=}"
}

# ------------------------------------------------ A. probe sites must not flip to the error arm
# With the pipe form, the first grep's early match SIGPIPEs the >128KB printf (rc 141) and the
# `|| _session_launch_error` arm dies the launch; the here-string form has no pipe at all.
run_launch _session_launch_droid
if [ "$RUN_RC" -eq 0 ] && [ "$RUN_LAUNCH" = "droid --auto medium" ]; then
  ok "droid probe: ${BYSZ}B help with the patterns present launches (rc 0, SESSION_LAUNCH=$RUN_LAUNCH)"
else
  bad "droid probe: >128KB help took the failure branch (rc=$RUN_RC out=$RUN_OUT launch=$RUN_LAUNCH)"
fi

PROVIDER="cursor"
run_launch _session_launch_cursor
if [ "$RUN_RC" -eq 0 ] && [ "$RUN_LAUNCH" = "cursor-agent" ]; then
  ok "cursor probe: ${BYSZ}B help with the patterns present launches (rc 0, SESSION_LAUNCH=$RUN_LAUNCH)"
else
  bad "cursor probe: >128KB help took the failure branch (rc=$RUN_RC out=$RUN_OUT launch=$RUN_LAUNCH)"
fi

PROVIDER="hermes"
run_launch _session_launch_hermes
if [ "$RUN_RC" -eq 0 ] && [ "$RUN_LAUNCH" = "hermes chat" ]; then
  ok "hermes probe: 2x${BYSZ}B help with the patterns present launches (rc 0, SESSION_LAUNCH=$RUN_LAUNCH)"
else
  bad "hermes probe: >128KB help took the failure branch (rc=$RUN_RC out=$RUN_OUT launch=$RUN_LAUNCH)"
fi

PROVIDER="cline"
run_launch _session_launch_cline
if [ "$RUN_RC" -eq 0 ] && [ "$RUN_LAUNCH" = "cline" ]; then
  ok "cline probe: ${BYSZ}B help with the patterns present launches (rc 0, SESSION_LAUNCH=$RUN_LAUNCH)"
else
  bad "cline probe: >128KB help took the failure branch (rc=$RUN_RC out=$RUN_OUT launch=$RUN_LAUNCH)"
fi

# ------------------------------------------------ B. _fleet_name_model must keep a valid reply
# The reply producer is the delegate's captured output; past the pipe buffer the emptiness
# check's early match SIGPIPEs it (rc 141) and `|| continue` threw the reply away, so naming
# fell through every model and returned 1. SCRIPT_PATH is pointed at a stub that emits a
# >128KB reply, and every CLI the model loop checks for is stubbed so the case is
# machine-independent.
printf '#!/usr/bin/env bash\nprintf "glm-5-2\\n"\ncat "%s"\nexit 0\n' "$TMP/big.txt" > "$TMP/stub-engine.sh"
chmod +x "$TMP/stub-engine.sh"
for cli in devin claude codex; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cli"; chmod +x "$BIN/$cli"
done
SCRIPT_PATH="$TMP/stub-engine.sh"
out="$(_fleet_name_model "name this model")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'glm-5-2' <<<"$out"; then
  ok "_fleet_name_model: a ${BYSZ}B reply is kept (rc 0, model line present)"
else
  bad "_fleet_name_model: >128KB reply discarded by the rc-141 continue (rc=$rc out-len=${#out})"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
