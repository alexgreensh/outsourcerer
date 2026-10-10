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

# ------------------------------------------------ C. same-shape sites fixed in the follow-up sweep
# Every verdict-consuming match below used to sit at the end of a `producer | grep -q` pipeline.
# With a producer larger than the pipe buffer and the needle on the FIRST line, grep exits early,
# the producer dies on SIGPIPE (rc 141), and pipefail flips the verdict to a miss.

# _session_droid_effort_supported: >128KB droid --help whose first line documents effort support.
{ printf '%s\n' "  -r, --reason <effort>  reasoning effort"; cat "$TMP/big.txt"; } > "$BIN/droid.help"
if _session_droid_effort_supported; then
  ok "_session_droid_effort_supported: ${BYSZ}B help with -r/reason present -> supported"
else
  bad "_session_droid_effort_supported: >128KB help misjudged as unsupported (rc-141 flip)"
fi
{ cat "$TMP/big.txt"; } > "$BIN/droid.help"   # restore the launch-test help body

# _devin_probe_classify: a >128KB probe reply whose FIRST line says pong must classify up.
_big_text="pong
$(cat "$TMP/big.txt")"
out="$(_devin_probe_classify 0 "$_big_text")"
if [ "$out" = "up" ]; then
  ok "_devin_probe_classify: ${BYSZ}B reply with pong -> up"
else
  bad "_devin_probe_classify: >128KB pong reply classified '$out' (rc-141 flip)"
fi

# _devin_free_own_quota: free-model name + quota-exhausted phrasing on line 1 of a >128KB reply.
_big_text="weekly usage quota for glm-5-2 exhausted
$(cat "$TMP/big.txt")"
if _devin_free_own_quota "glm-5-2" "$_big_text"; then
  ok "_devin_free_own_quota: ${BYSZ}B reply with the free-model quota phrase -> matched"
else
  bad "_devin_free_own_quota: >128KB quota reply missed (rc-141 flip)"
fi

# _frontier_needed: 'mission-critical' on line 1 of a >128KB task text must request the frontier.
_big_text="mission-critical refactor
$(cat "$TMP/big.txt")"
if _frontier_needed "$_big_text" ""; then
  ok "_frontier_needed: ${BYSZ}B task with the cue present -> frontier"
else
  bad "_frontier_needed: >128KB task misjudged (rc-141 flip)"
fi

# _so_has_neg: a negation cue on line 1 of a >128KB answer must read as negated. A miss here is
# the unsafe direction (a contradiction scoring as agreement skips the judge).
_big_text="cannot deploy this
$(cat "$TMP/big.txt")"
if printf '%s' "$_big_text" | _so_has_neg; then
  ok "_so_has_neg: ${BYSZ}B answer with a negation cue -> negation"
else
  bad "_so_has_neg: >128KB answer read as no-negation (rc-141 false-agree)"
fi

# _is_transport_failure: a line-anchored transport signature on line 1 of >128KB stderr.
_big_text="error: connection refused
$(cat "$TMP/big.txt")"
if _is_transport_failure "$_big_text" 1; then
  ok "_is_transport_failure: ${BYSZ}B stderr with the signature -> transport"
else
  bad "_is_transport_failure: >128KB stderr misclassified as task failure (rc-141 flip)"
fi

# _is_sandboxed_proxy_tls_failure: both machine tokens present early in a >128KB devin log.
_big_text="rustls_platform_verifier OSStatus -67808
$(cat "$TMP/big.txt")"
if _is_sandboxed_proxy_tls_failure "$_big_text"; then
  ok "_is_sandboxed_proxy_tls_failure: ${BYSZ}B log with both tokens -> tls failure"
else
  bad "_is_sandboxed_proxy_tls_failure: >128KB log missed (rc-141 flip)"
fi

# _session_help_has_model_flag: --model on line 1 of a >128KB help must read as pinnable.
_big_text="--model <id>
$(cat "$TMP/big.txt")"
if _session_help_has_model_flag "$_big_text"; then
  ok "_session_help_has_model_flag: ${BYSZ}B help with --model -> pinnable"
else
  bad "_session_help_has_model_flag: >128KB help misjudged (rc-141 flip)"
fi

# _secret_scan VALUE hard-block: a real key VALUE on line 1 of a >128KB prompt must still die.
# A miss here is the dangerous direction (a live credential shipped to a cloud lane).
_big_text="sk-AbCdEfGhIjKlMnOpQrStUvWx
$(cat "$TMP/big.txt")"
_out="$(cd "$TMP" && OSRC_SECRET_SCAN_DEEP=0 _secret_scan "$_big_text" dv 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'CLOUD GATE' <<<"$_out"; then
  ok "_secret_scan: ${BYSZ}B prompt carrying a key VALUE -> hard-blocked"
else
  bad "_secret_scan: >128KB prompt with a live key passed the VALUE gate (rc-141 fail-open)"
fi

# _crew_scan_staged: a staged diff whose first hunk plants a key must read as dirty even when the
# diff outgrows the pipe buffer (git would take the SIGPIPE on grep's early exit).
if have git; then
  GIT_DIR_T="$TMP/crewg"; mkdir -p "$GIT_DIR_T"
  git -C "$GIT_DIR_T" init -q 2>/dev/null
  git -C "$GIT_DIR_T" config user.email t@t 2>/dev/null; git -C "$GIT_DIR_T" config user.name t 2>/dev/null
  printf 'baseline\n' > "$GIT_DIR_T/f.txt"
  git -C "$GIT_DIR_T" add f.txt 2>/dev/null && git -C "$GIT_DIR_T" commit -qm base 2>/dev/null
  { printf 'sk-AbCdEfGhIjKlMnOpQrStUvWx\n'; cat "$TMP/big.txt"; } > "$GIT_DIR_T/f.txt"
  git -C "$GIT_DIR_T" add f.txt 2>/dev/null
  if _crew_scan_staged "$GIT_DIR_T"; then
    ok "_crew_scan_staged: ${BYSZ}B staged diff carrying a key -> detected"
  else
    bad "_crew_scan_staged: >128KB staged diff read as clean (rc-141 fail-open)"
  fi
else
  echo "SKIP: git not on PATH; _crew_scan_staged untested"
fi

# _codex_image_available: `codex features list` >128KB with both features on the first lines.
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "$1" = "login" ]; then printf "logged in\\n"; exit 0; fi\n'
  printf 'if [ "$1" = "features" ]; then printf "image_generation\\nartifact\\n"; cat "%s"; exit 0; fi\n' "$TMP/big.txt"
  printf 'exit 0\n'
} > "$BIN/codex"
chmod +x "$BIN/codex"
_OSRC_CODEX_IMG=""
if _codex_image_available; then
  ok "_codex_image_available: ${BYSZ}B features list with both tokens -> available"
else
  bad "_codex_image_available: >128KB features list misjudged (rc-141 flip)"
fi

# logged_in / _fallback_lane_ready(dv) / _ready_lanes: `devin auth status` >128KB with the
# "Logged in" marker on the first line.
# Note: the stub ends on `cat` with no trailing `exit 0` so a SIGPIPE kill of the producer
# propagates as the stub's real exit status (141) instead of being masked by the wrapper.
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "$1" = "auth" ]; then printf "Logged in as t\\n"; cat "%s"; fi\n' "$TMP/big.txt"
  printf 'if [ "$1" = "--model" ]; then printf "Available: glm-5-2, swe-2\\n"; exit 0; fi\n'
} > "$BIN/devin"
chmod +x "$BIN/devin"
if logged_in; then
  ok "logged_in: ${BYSZ}B auth status with the marker -> logged in"
else
  bad "logged_in: >128KB auth status read as logged out (rc-141 flip)"
fi
if _fallback_lane_ready dv; then
  ok "_fallback_lane_ready dv: ${BYSZ}B auth status -> lane ready"
else
  bad "_fallback_lane_ready dv: >128KB auth status read as not ready (rc-141 flip)"
fi
lanes="$(_ready_lanes 2>/dev/null)"
case " $lanes " in
  *" devin="*) ok "_ready_lanes: ${BYSZ}B auth status -> devin lane listed" ;;
  *)           bad "_ready_lanes: >128KB auth status dropped the devin lane (rc-141 flip): '$lanes'" ;;
esac

# _devin_probe_classify free-model quota path through the classifier: paid phrasing on line 1.
_big_text="weekly usage quota has been exhausted
$(cat "$TMP/big.txt")"
out="$(_devin_probe_classify 1 "$_big_text")"
if [ "$out" = "paid-tier-exhausted" ]; then
  ok "_devin_probe_classify: ${BYSZ}B refusal -> paid-tier-exhausted"
else
  bad "_devin_probe_classify: >128KB refusal classified '$out' (rc-141 flip)"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
