#!/usr/bin/env bash
# test_model_drift.sh — a run that STARTS on the requested model and switches mid-flight must be caught.
#
# A native lane can silently fall back to the account default part-way through a run. The old check read
# only the FIRST modelUsage entry, so a run that opened on the requested model and finished on another
# printed "verified" — the single most misleading thing a verifier can do, because the receipt is used
# to label the output. Attribution has to cover the whole run, not its opening turn.
#
# Also asserted: the cloud banner must name always-on rule files pulled from $HOME. Those sit outside
# the delegated working dir, so a banner listing only "this working dir + --with files" is describing a
# smaller blast radius than the one that applies — and being instructions, they steer the delegate too.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1
type -t _cc_verify_model >/dev/null || { echo "FAIL: _cc_verify_model not loaded"; exit 1; }
type -t _rule_files_note >/dev/null || { echo "FAIL: _rule_files_note not loaded"; exit 1; }

# --- clean run: only the requested model ----------------------------------------------------------
printf '{"modelUsage":{"claude-fable-5":{"inputTokens":10,"outputTokens":20}}}\n' > "$TMP/clean.json"
out="$(_cc_verify_model fable "$TMP/clean.json" 2>&1)"
case "$out" in *"[verified]"*) ok "a run that stayed on the requested model verifies clean" ;;
  *) bad "clean run did not verify: $out" ;; esac
case "$out" in *"DRIFT"*) bad "a clean run was reported as drift" ;; *) ok "no false drift on a clean run" ;; esac

# --- the dangerous case: started right, drifted later ---------------------------------------------
# Two keys in modelUsage = two models billed. Reading only the first says "verified".
printf '{"modelUsage":{"claude-fable-5":{"outputTokens":20},"claude-opus-4-8":{"outputTokens":900}}}\n' > "$TMP/drift.json"
out="$(_cc_verify_model fable "$TMP/drift.json" 2>&1)"; rc=$?
case "$out" in *"MODEL DRIFT"*) ok "a mid-run fallback is caught even though the run started correctly" ;;
  *) bad "mid-run drift was NOT caught (this is the exact silent-fallback case): $out" ;; esac
case "$out" in *opus*) ok "the drift report names the model it fell back to" ;;
  *) bad "drift report does not name the other model" ;; esac
case "$out" in *"[verified]"*) bad "a drifted run still printed a clean verified receipt" ;;
  *) ok "a drifted run never prints a clean verified receipt" ;; esac
[ "$rc" != "0" ] && ok "drift returns non-zero so a caller can act on it" || bad "drift returned 0"
case "$out" in *"session model fable"*) ok "the drift report names the concrete correction command" ;;
  *) bad "no remedy given for drift" ;; esac
# Usage is only reported when the run ENDS, so this is a post-hoc receipt. Offering to "abort instead
# of drifting" would promise an interception the tool cannot perform.
case "$out" in *"after the fact"*) ok "it states the drift was found after the run, not intercepted" ;;
  *) bad "the report implies it can intercept drift live" ;; esac
case "$out" in *"abort instead of drifting"*) bad "promises an abort it cannot deliver post-hoc" ;;
  *) ok "no promise of an abort that cannot happen" ;; esac
case "$out" in *"restored"*) bad "post-hoc verifier claims a live restore" ;;
  *) ok "post-hoc verifier remains advisory" ;; esac

# --- wrong model entirely -------------------------------------------------------------------------
printf '{"modelUsage":{"claude-opus-4-8":{"outputTokens":900}}}\n' > "$TMP/wrong.json"
out="$(_cc_verify_model fable "$TMP/wrong.json" 2>&1)"
case "$out" in *WARNING*) ok "a run entirely on another model is still reported" ;;
  *) bad "wrong-model run not reported: $out" ;; esac

# --- no usage data: stay silent rather than invent a verdict ---------------------------------------
printf '{"result":"hello"}\n' > "$TMP/none.json"
out="$(_cc_verify_model fable "$TMP/none.json" 2>&1)"
[ -z "$out" ] && ok "with no usage data it says nothing rather than guessing" \
              || bad "invented a verdict with no usage data: $out"

# --- the banner must not understate what leaves the machine ---------------------------------------
HOME_REAL="$HOME"; HOME="$TMP/home"; mkdir -p "$TMP/home/.claude"
printf 'some global rules\n' > "$TMP/home/.claude/CLAUDE.md"
note="$(_rule_files_note 2>&1)"
HOME="$HOME_REAL"
case "$note" in *CLAUDE.md*) ok "the disclosure names the always-on rule file pulled from \$HOME" ;;
  *) bad "always-on rule files are not disclosed" ;; esac
case "$note" in *"steer the delegate"*) ok "it says these are instructions, not just data" ;;
  *) bad "the instruction-contamination risk is not stated" ;; esac
# The remedy must be one that EXISTS. An invented env var reads as a real control and silently does
# nothing, which is worse than saying "we cannot turn this off from here".
case "$note" in *"devin rules list"*) ok "it names a real, existing command to inspect the rules" ;;
  *) bad "no usable remedy named" ;; esac
case "$note" in *OSRC_NO_HOME_RULES*) bad "advertises a suppression knob that is not implemented" ;;
  *) ok "does not advertise an unimplemented knob" ;; esac

# and stays quiet when there is nothing to disclose
HOME="$TMP/empty"; mkdir -p "$TMP/empty"
note="$(_rule_files_note 2>&1)"; HOME="$HOME_REAL"
[ -z "$note" ] && ok "no note when there are no always-on rule files (never cries wolf)" \
               || bad "printed a disclosure with no rule files present"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
