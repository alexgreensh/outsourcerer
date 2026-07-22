#!/usr/bin/env bash
# test_perm_denial_precision.sh — _perm_denials must count REAL permission/sandbox
# denials and must NOT count a delegate merely reading about permissions.
#
# Root cause this guards: the original detector grepped the whole log for
# 'permission denied|EACCES|operation not permitted|read-only file system', which
# counts source code the delegate READ as denials the delegate SUFFERED. Real mutating
# runs have been aborted deep into their work where every match was Python they had
# read — `except PermissionError:` handlers and a regex literal listing "permission
# denied" as an error word — with zero actual denials. Any delegate working on
# error-handling code, a log parser, or on this tool itself trips it.
#
# The guard must stay SHARP in both directions: a detector that never fires is a
# worse bug than the false positive, because it silently removes the wall-off
# backstop while still advertising it.
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

. "$SRC" >/dev/null 2>&1

type _perm_denials >/dev/null 2>&1 || { echo "FAIL: _perm_denials not defined"; exit 1; }

count_of() { local f="$TMP/probe.log"; printf '%s\n' "$1" > "$f"; _perm_denials "$f"; }

# ---------------------------------------------------------------- NEGATIVES
# Verbatim shapes from the real 14-minute run that was falsely killed.
neg_source_handler='{"type":"user","message":{"content":[{"type":"tool_result","content":"        except PermissionError:\n            print(f\"    PID {s[pid]} permission denied (owned by another user).\")"}]}}'
neg_source_write='{"type":"user","message":{"content":[{"type":"tool_result","content":"    except PermissionError:\n        print(f\"[Error] Permission denied writing {SETTINGS_PATH}.\")"}]}}'
neg_regex_literal='{"type":"user","message":{"content":[{"type":"tool_result","content":"    r\"\\bfatal:|\"\n    r\"\\bpermission denied\\b|\"\n    r\"\\bno such file or directory\\b|\""}]}}'
neg_prose='{"type":"assistant","message":{"content":[{"type":"text","text":"The script handles EACCES and read-only file system errors gracefully."}]}}'

for pair in "echoed except-PermissionError handler:$neg_source_handler" \
            "echoed Permission-denied-writing branch:$neg_source_write" \
            "echoed regex literal listing permission denied:$neg_regex_literal" \
            "assistant prose mentioning EACCES:$neg_prose"; do
  label="${pair%%:*}"; body="${pair#*:}"
  n="$(count_of "$body")"
  [ "$n" = "0" ] && ok "no false count — $label" || bad "false positive ($n) — $label"
done

# ---------------------------------------------------------------- POSITIVES
# Verbatim devin rejection, captured from the real CLI during root-cause work.
pos_devin='Tool execution was rejected: Running in non-interactive mode. Use --permission-mode dangerous to auto-approve all tools.'
pos_printmode='2026-07-22T08:15:50Z INFO chisel::repl::handler: Print mode: rejecting tool exec that requires confirmation'
pos_claude='Claude requested permissions to write to /etc/hosts, but you have not granted it yet'
pos_iserr_eacces='{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"EACCES: permission denied, open /etc/hosts"}]}}'
pos_iserr_ro='{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"error: Read-only file system (os error 30)"}]}}'

for pair in "devin non-interactive rejection:$pos_devin" \
            "devin print-mode rejection:$pos_printmode" \
            "claude permission request:$pos_claude" \
            "is_error tool_result with EACCES:$pos_iserr_eacces" \
            "is_error tool_result read-only fs:$pos_iserr_ro"; do
  label="${pair%%:*}"; body="${pair#*:}"
  n="$(count_of "$body")"
  [ "${n:-0}" -ge 1 ] && ok "detected — $label" || bad "MISSED real denial — $label"
done

# ------------------------------------------------------- THRESHOLD BEHAVIOUR
# Three real denials must reach the default abort threshold; three echoed
# handlers must not.
real3="$TMP/real3.log"; : > "$real3"
for i in 1 2 3; do printf '%s\n' "$pos_iserr_eacces" >> "$real3"; done
n="$(_perm_denials "$real3")"
[ "${n:-0}" -ge 3 ] && ok "3 real denials reach the abort threshold ($n)" \
                    || bad "3 real denials did not reach threshold (got $n)"

fake3="$TMP/fake3.log"; : > "$fake3"
for i in 1 2 3; do printf '%s\n' "$neg_source_handler" >> "$fake3"; done
n="$(_perm_denials "$fake3")"
[ "${n:-0}" -lt 3 ] && ok "3 echoed handlers stay under the abort threshold ($n)" \
                    || bad "3 echoed handlers would still abort a healthy job (got $n)"

# A real denial must still be found when it sits at the end of a long, noisy log
# (the tail-scan window must not be so tight that a genuine wall is missed).
noisy="$TMP/noisy.log"; : > "$noisy"
for i in $(seq 1 120); do printf '%s\n' "$neg_prose" >> "$noisy"; done
for i in 1 2 3; do printf '%s\n' "$pos_devin" >> "$noisy"; done
n="$(_perm_denials "$noisy")"
[ "${n:-0}" -ge 3 ] && ok "real wall at end of a noisy log still aborts ($n)" \
                    || bad "real wall at end of noisy log missed (got $n)"

# ------------------------------------------------------- SELF-TRIGGER GUARD
# The measured top false-positive source: a delegate that reads or greps
# outsourcerer.sh echoes the detector's own pattern line into its log. If the
# trigger phrases live in this script as literals, working ON this tool aborts
# the job that is doing the work — and the print-mode variant aborts on a SINGLE
# occurrence with no threshold, at whatever point the read happens (typically the
# end of a run that has already done everything).
selfsrc="$TMP/selfsrc.log"
sed 's/^/{"type":"user","message":{"content":[{"type":"tool_result","content":"/' "$SRC" > "$selfsrc"
n="$(_perm_denials "$selfsrc")"
[ "${n:-0}" -eq 0 ] && ok "reading outsourcerer.sh does not trip _perm_denials ($n)" \
                    || bad "SELF-TRIGGER: reading outsourcerer.sh scores $n denials"

# Same guard for the print-mode needle, which aborts on one hit.
if grep -aq "$(_printmode_needle)" "$SRC" 2>/dev/null; then
  bad "SELF-TRIGGER: outsourcerer.sh contains the print-mode needle verbatim"
else
  ok "outsourcerer.sh does not contain the print-mode needle verbatim"
fi

# The needles must still be correct, not merely absent: assert they match a real
# devin emission. An assembled needle that assembles WRONG is a silently dead guard.
real_pm='2026-07-22T08:15:50Z INFO chisel::repl::handler: Print mode: rejecting tool exec that requires confirmation'
printf '%s\n' "$real_pm" | grep -aq "$(_printmode_needle)" \
  && ok "print-mode needle still matches a real devin log line" \
  || bad "print-mode needle does NOT match a real devin log line (guard is dead)"

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
