#!/usr/bin/env bash
# test_devin_org_policy_posture.sh — a Devin org-policy refusal of sandboxed-'autonomous'
# must be DETECTED, REMEMBERED, and then preflight-skipped, so `research` stops re-nagging
# with the same scary error every run.
#
# Root cause this guards: delegate() passed --permission-mode autonomous --sandbox to devin on
# every research run; when the org forbids it, devin returns "Mode 'autonomous' is restricted by
# your organization's policy" and the tool fired a "retry with yolo" hint — wrong (yolo is LESS
# safe) — and never remembered the verdict, so the identical failure re-printed on every dispatch.
#
# The guard must stay SHARP both ways: the detector must fire on the real refusal AND must NOT fire
# on an unrelated failure (a Connection/TLS error, or a delegate merely reading about the policy).
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

for fn in _devin_autonomous_policy_blocked _posture_set _posture_get cmd_posture; do
  type "$fn" >/dev/null 2>&1 || { echo "FAIL: $fn not defined"; exit 1; }
done

# ---------------------------------------------------------------- DETECTOR (positive)
real_err="$TMP/real.err"
cat > "$real_err" <<'EOF'
>>> [route] RESOLVED lane=devin model=glm-5.2 explicit=--provider devin
Error: session/set_mode failed: Invalid params: "Mode 'autonomous' is restricted by your organization's policy"
EOF
if _devin_autonomous_policy_blocked "$real_err"; then ok "detector fires on the real org-policy refusal"
else bad "detector missed the real org-policy refusal"; fi

# ---------------------------------------------------------------- DETECTOR (negatives)
tls_err="$TMP/tls.err"
printf 'Error: Connection error (rustls OSStatus cert-verify failed)\n' > "$tls_err"
if _devin_autonomous_policy_blocked "$tls_err"; then bad "detector false-positived on an unrelated TLS error"
else ok "detector ignores an unrelated TLS/connection failure"; fi

prose_err="$TMP/prose.err"
printf 'The delegate read a doc explaining that some modes may be restricted by org policy.\n' > "$prose_err"
if _devin_autonomous_policy_blocked "$prose_err"; then bad "detector false-positived on prose merely mentioning restrictions"
else ok "detector ignores prose that only mentions restrictions"; fi

if _devin_autonomous_policy_blocked "$TMP/does-not-exist"; then bad "detector fired on a missing capture file"
else ok "detector safe on a missing capture file"; fi

# ---------------------------------------------------------------- POSTURE roundtrip
_posture_get devin autonomous >/dev/null 2>&1 && bad "posture reported a value before any was set" || ok "posture absent before set"

_posture_set devin autonomous restricted || bad "_posture_set failed"
val="$(_posture_get devin autonomous 2>/dev/null)"
[ "$val" = "restricted" ] && ok "posture roundtrips (set -> get = restricted)" || bad "posture roundtrip wrong (got '$val')"

# stored file must be private and NOT a symlink target we honor
pf="$OSRC_HOME/lane-posture/devin.autonomous"
[ -f "$pf" ] && ok "posture stored as a real file" || bad "posture file missing after set"
mode="$(stat -c '%a' "$pf" 2>/dev/null || stat -f '%Lp' "$pf" 2>/dev/null)"
[ "$mode" = "600" ] && ok "posture file is 0600" || bad "posture file mode is '$mode', expected 600"

# symlink defense: a planted symlink must NOT be read as a stored posture
rm -f "$pf"
ln -s /etc/hosts "$pf" 2>/dev/null
if _posture_get devin autonomous >/dev/null 2>&1; then bad "posture_get read through a planted symlink"
else ok "posture_get refuses a symlinked posture file"; fi
rm -f "$pf"

# ---------------------------------------------------------------- cmd_posture surface
out="$(cmd_posture status 2>&1)"; case "$out" in *"no lane postures"*) ok "posture status: empty state message" ;; *) bad "posture status empty-state wrong: $out" ;; esac
_posture_set devin autonomous restricted
out="$(cmd_posture status 2>&1)"; case "$out" in *"devin.autonomous = restricted"*) ok "posture status lists the remembered restriction" ;; *) bad "posture status did not list the restriction: $out" ;; esac
cmd_posture reset >/dev/null 2>&1
_posture_get devin autonomous >/dev/null 2>&1 && bad "posture reset did not clear the restriction" || ok "posture reset clears remembered restrictions"

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
