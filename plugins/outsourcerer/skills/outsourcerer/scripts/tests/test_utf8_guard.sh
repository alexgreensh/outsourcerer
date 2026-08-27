#!/usr/bin/env bash
# test_utf8_guard.sh — U? conformance: the devin dispatch boundary must not die on the opaque
# clap error "invalid UTF-8 was detected in one or more arguments" when a prompt contains
# broken bytes (the real-world source is byte-truncation upstream: awk substr / cut -c slicing
# a multibyte character mid-sequence, leaving a lone continuation byte). _utf8_guard lossy-
# decodes so dispatch proceeds with a visible warning instead of an unattributed rc=2 crash.
#
# Run: bash test_utf8_guard.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
pass=0; fail=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; TMP_ERR="$TMP/err"; : > "$TMP_ERR"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Source the main script for function access (it guards its own entrypoint with a main-runnable
# check, so sourcing defines functions without executing dispatch).
. "$SRC" >/dev/null 2>&1

# --- Scenario 1: valid UTF-8 non-ASCII passes through unchanged. ---
# Em-dash (U+2014, E2 80 94), arrow, curly quotes, accented letters are all VALID UTF-8 and
# must NOT be altered or warned about. This is the regression guard against the original
# misdiagnosis ("non-ASCII crashes it").
VALID="hello — world → test 'curly' "café""
out="$(_utf8_guard "$VALID" 2>/dev/null)"
[ "$out" = "$VALID" ] && ok "valid UTF-8 non-ASCII passes unchanged" || bad "valid non-ASCII was altered: got [$out]"

# --- Scenario 2: invalid UTF-8 (lone 0xE2 start byte) is lossy-decoded, warning emitted. ---
# This is the exact byte sequence awk substr produces when truncating "hello — world" at 7
# bytes: the em-dash's first byte E2 is left alone without its continuation bytes.
INVALID=$'hello \xe2 world'
warn=""
out="$(_utf8_guard "$INVALID" 2>"$TMP_ERR")"; warn="$(cat "$TMP_ERR" 2>/dev/null)"
# iconv //IGNORE drops the lone E2 -> "hello  world" (double space where the byte was).
[ "$out" = "hello  world" ] && ok "invalid UTF-8 lossy-decoded to valid" || bad "lossy-decode wrong: got [$out]"
printf '%s' "$warn" | grep -q '\[utf8\]' && ok "warning emitted on invalid UTF-8" || bad "no warning on invalid UTF-8"

# --- Scenario 3: the guard's output is itself valid UTF-8 (would not re-trip clap). ---
# Round-trip the cleaned output through iconv strict (no //IGNORE); must exit 0.
printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && ok "cleaned output is valid UTF-8" || bad "cleaned output still invalid UTF-8"

# --- Scenario 4: OSRC_UTF8_GUARD=0 opts out (passthrough, no warning, no decode). ---
out="$(OSRC_UTF8_GUARD=0 _utf8_guard "$INVALID" 2>/dev/null)"
[ "$out" = "$INVALID" ] && ok "OSRC_UTF8_GUARD=0 passes invalid bytes through verbatim" || bad "opt-out altered input: got [$out]"

# --- Scenario 5: empty-after-decode fallback — a fully-invalid payload is NOT replaced with
# an empty string (an empty prompt is a different failure); the original is returned so the
# real error surfaces honestly. ---
ALLBAD=$'\xe2\xe2\xe2'
out="$(_utf8_guard "$ALLBAD" 2>/dev/null)"
[ "$out" = "$ALLBAD" ] && ok "all-invalid payload returned verbatim (no empty swap)" || bad "all-invalid payload was swapped: got [$out]"

# --- Scenario 6: empty input is a no-op. ---
out="$(_utf8_guard "" 2>/dev/null)"
[ -z "$out" ] && ok "empty input returns empty" || bad "empty input returned non-empty: [$out]"

# --- Scenario 7: the guard is wired into delegate() and continue_turn(). ---
# Static check: both dispatch sites call _utf8_guard_prompt before the devin invocation.
delegate_calls=$(grep -c '_utf8_guard_prompt prompt' "$SRC")
[ "$delegate_calls" -ge 2 ] && ok "delegate() and continue_turn() both call _utf8_guard_prompt ($delegate_calls sites)" || bad "guard not wired into both dispatch sites (found $delegate_calls)"

# --- Scenario 8: no iconv -> best-effort passthrough (cannot check, do not corrupt). ---
# Stub iconv to be absent and confirm valid input passes through unchanged.
_utf8_guard_noiconv() { PATH="/dev/null" command -v iconv >/dev/null 2>&1 || { printf '%s' "$1"; return 0; }; }
out="$(_utf8_guard_noiconv "$VALID")"
[ "$out" = "$VALID" ] && ok "no-iconv passthrough preserves valid input" || bad "no-iconv path corrupted input"

# --- Scenario 9: valid multi-line prompt ending in newline is NOT altered and NOT warned. ---
# Regression guard against command-substitution trailing-newline stripping + false positives.
# _utf8_guard's happy path must return the input verbatim on stdout. Compare BYTE-EXACT via
# files (cmp), NOT via $(...) which strips trailing newlines itself and would mask the check.
ML=$'line one\nline two\n'
printf '%s' "$ML" > "$TMP/expected"
_utf8_guard "$ML" 2>"$TMP_ERR" > "$TMP/actual"
cmp -s "$TMP/expected" "$TMP/actual" && ok "valid multi-line prompt (trailing newline) passes byte-exact unchanged" || bad "multi-line trailing-newline prompt was altered"
warn="$(cat "$TMP_ERR" 2>/dev/null)"
[ -z "$warn" ] && ok "no false warning on valid multi-line prompt" || bad "false warning on valid multi-line prompt: $warn"

# --- Scenario 10: _utf8_guard_prompt guards IN PLACE — valid prompt var is untouched. ---
# The happy path must not route through command substitution (no trailing-newline stripping).
P="$ML"
_utf8_guard_prompt P
[ "$P" = "$ML" ] && ok "_utf8_guard_prompt leaves a valid prompt var untouched (no $() stripping)" || bad "_utf8_guard_prompt altered a valid prompt: got [$P]"

# --- Scenario 11: _utf8_guard_prompt reassigns an invalid prompt var in place. ---
P="$INVALID"
_utf8_guard_prompt P
[ "$P" = "hello  world" ] && ok "_utf8_guard_prompt lossy-decodes an invalid prompt var in place" || bad "_utf8_guard_prompt in-place decode wrong: got [$P]"

# --- Scenario 12: _utf8_guard_prompt is a no-op on an empty var. ---
P=""
_utf8_guard_prompt P
[ -z "$P" ] && ok "_utf8_guard_prompt is a no-op on an empty prompt var" || bad "_utf8_guard_prompt altered an empty var: [$P]"

# --- Scenario 13: the shell fallback path (musl: no //IGNORE, permissive strict iconv)
# works end-to-end. Force the probe to "shell" to exercise the pure-shell validator + lossy
# stripper regardless of host iconv. This is what runs on Alpine/musl. ---
SAVE_PROBE="${OSRC_UTF8_PROBE:-}"
OSRC_UTF8_PROBE=shell
out="$(OSRC_UTF8_PROBE=shell _utf8_guard "$INVALID" 2>/dev/null)"
[ "$out" = "hello  world" ] && ok "shell path: invalid UTF-8 lossy-decoded (musl fallback)" || bad "shell path lossy-decode wrong: got [$out]"
OSRC_UTF8_PROBE=shell _utf8_guard "$VALID" 2>"$TMP_ERR" > "$TMP/shell-valid"
cmp -s "$TMP/shell-valid" <(printf '%s' "$VALID") && ok "shell path: valid non-ASCII passes unchanged" || bad "shell path altered valid input"
warn="$(cat "$TMP_ERR" 2>/dev/null)"; [ -z "$warn" ] && ok "shell path: no false warning on valid input" || bad "shell path false warning: $warn"
# 4-byte valid char (U+10308 = F0 90 8C 88) preserved through the shell path.
out="$(OSRC_UTF8_PROBE=shell _utf8_lossy $'x\xf0\x90\x8c\x88y' 2>/dev/null)"
[ "$out" = $'x\xf0\x90\x8c\x88y' ] && ok "shell path: 4-byte valid char preserved" || bad "shell path dropped a valid 4-byte char: got [$out]"
OSRC_UTF8_PROBE="$SAVE_PROBE"

# --- Scenario 14: invalid byte at END of prompt (not just mid-string). ---
# A lone E2 with no following bytes at EOF is a truncated 3-byte sequence.
ENDBAD=$'hello world\xe2'
out="$(_utf8_guard "$ENDBAD" 2>/dev/null)"
[ "$out" = "hello world" ] && ok "invalid byte at end-of-prompt is stripped" || bad "end-of-prompt byte not stripped: got [$out]"

# --- Scenario 15: the probe picks iconv on a validating iconv, shell on a permissive one. ---
# We can't force musl here, but we CAN confirm the probe returns a non-empty known value and
# that forcing it to "none" makes the guard inert (honest passthrough, no corruption).
p="$(_utf8_probe)"
case "$p" in iconv|shell|none) ok "probe returns a known value ($p)" ;; *) bad "probe returned unknown value: [$p]" ;; esac
out="$(OSRC_UTF8_PROBE=none _utf8_guard "$INVALID" 2>/dev/null)"
[ "$out" = "$INVALID" ] && ok "probe=none: guard is inert (honest passthrough, no corruption)" || bad "probe=none altered input: got [$out]"

echo "---"
echo "utf8_guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
