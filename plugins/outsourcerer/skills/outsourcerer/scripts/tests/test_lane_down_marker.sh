#!/usr/bin/env bash
# test_lane_down_marker.sh — the LANE-DOWN posture marker primitives (_lane_down_mark /
# _lane_down_active). Sibling of the quota exhausted-until marker; strict-direction, self-healing
# TTL, keyed by LANE (not model), expired markers self-purge value-matched. These primitives are
# inert until a dispatch gate consults them (see the PR's wiring proposal) — this test pins the
# primitive contract so the wiring can be reviewed/added safely.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"; export HOME="$TMP"
cleanup() { rm -rf "$TMP"; }; trap cleanup EXIT
. "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# Clean: no marker -> not down.
if _lane_down_active dv; then bad "clean: dv reported down with no marker"; else ok "clean: dv not down initially"; fi

# Mark down -> active within TTL.
_lane_down_mark dv 300
if _lane_down_active dv; then ok "marked: dv down within TTL"; else bad "marked: dv NOT down after mark"; fi

# Lane keying: a dispatch/provider name folds to the same lane code as the marker.
if _lane_down_active devin; then ok "keying: 'devin' folds to dv (same marker)"; else bad "keying: 'devin' did not match the dv marker"; fi

# Isolation: a DIFFERENT lane is unaffected.
if _lane_down_active or; then bad "isolation: 'or' falsely reported down"; else ok "isolation: 'or' unaffected by the dv marker"; fi

# Strict direction: an already-expired marker is NOT active and is purged on read.
_posture_set cx down 1   # epoch 1 (1970) -> long expired
if _lane_down_active cx; then bad "expired: cx still reported down"; else ok "expired: cx not active"; fi
if [ -e "$OSRC_POSTURE_DIR/cx.down" ]; then bad "expired: marker file not purged on read"; else ok "expired: marker file purged on read"; fi

# Expiry purges the marker's reason/evidence too (same file set as _lane_down_clear): a down
# explanation must not outlive the mark it explains or `posture status` shows stale quota wording.
_posture_set cx down 1; _posture_set cx down-reason "plan quota exhausted"; _posture_set cx down-evidence "Error: quota"
_lane_down_active cx || true
if [ -e "$OSRC_POSTURE_DIR/cx.down-reason" ] || [ -e "$OSRC_POSTURE_DIR/cx.down-evidence" ]; then bad "expired: reason/evidence outlived the purged marker"; else ok "expired: reason+evidence purged with the marker"; fi

# Junk value never reads as down (hardening: non-numeric posture value).
_posture_set gm down "not-a-number"
if _lane_down_active gm; then bad "junk: non-numeric marker read as down"; else ok "junk: non-numeric marker ignored"; fi

# An unexpired LONGER mark wins: a bare short re-mark (doctor/TLS verdict inside a confirmed quota
# window) must not cut the window or erase its reason/evidence; a LONGER re-mark still extends the
# mark and re-asserts/drops aux files per its own args.
_lane_down_mark dv 3000 "plan quota exhausted" "Error: Your daily usage quota has been exhausted"
_kept="$(_posture_get dv down 2>/dev/null)"
_lane_down_mark dv    # bare transport re-mark (300s) -> must be a no-op against the 3000s mark
[ "$(_posture_get dv down 2>/dev/null)" = "$_kept" ] && ok "guard: bare short re-mark is a no-op on a longer mark" || bad "guard: shorter re-mark overwrote the marker"
[ -f "$OSRC_POSTURE_DIR/dv.down-reason" ] && [ -f "$OSRC_POSTURE_DIR/dv.down-evidence" ] && ok "guard: reason+evidence kept under the longer mark" || bad "guard: bare re-mark erased aux files"
_lane_down_mark dv 9000
_nu="$(_posture_get dv down 2>/dev/null)"; [ "${_nu:-0}" -gt "${_kept:-0}" ] && ok "guard: longer re-mark still extends the window" || bad "guard: longer re-mark blocked (${_nu} vs ${_kept})"
[ ! -e "$OSRC_POSTURE_DIR/dv.down-reason" ] && [ ! -e "$OSRC_POSTURE_DIR/dv.down-evidence" ] && ok "guard: extending bare re-mark drops stale aux (fresh verdict wins)" || bad "guard: stale aux survived a longer bare re-mark"

# A REASONED shorter re-mark is authoritative fresher information (the provider's own stated
# reset): it replaces the current mark as a unit -- window, reason, evidence together. The
# keep-longer guard exists only for bare transport verdicts and must not absorb it.
_lane_down_mark or 3600 "plan quota exhausted" "estimate: reset unknown"
_lane_down_mark or 780 "plan quota exhausted" "plan resets in 13m (provider stated)"
_now="$(date +%s)"; _u="$(_posture_get or down 2>/dev/null)"
{ [ "${_u:-0}" -ge "$((_now + 700))" ] && [ "${_u:-0}" -le "$((_now + 800))" ]; } && ok "reset: reasoned shorter mark writes its own window" || bad "reset: shorter reasoned mark kept the old window (delta $(( ${_u:-0} - _now ))s)"
[ "$(cat "$OSRC_POSTURE_DIR/or.down-reason" 2>/dev/null)" = "plan quota exhausted" ] && ok "reset: reason carried through" || bad "reset: reason wrong"
[ "$(cat "$OSRC_POSTURE_DIR/or.down-evidence" 2>/dev/null)" = "plan resets in 13m (provider stated)" ] && ok "reset: evidence replaced with the new mark" || bad "reset: stale evidence kept"
# A reasoned LONGER re-mark extends normally too (same replace-unit path, just a bigger window).
_lane_down_mark or 7200 "plan quota exhausted" "plan resets in 2h"
_u="$(_posture_get or down 2>/dev/null)"
[ "${_u:-0}" -gt "$((_now + 3600))" ] && ok "reset: reasoned longer mark extends" || bad "reset: reasoned longer mark blocked"
# ...and once a reasoned mark owns the window, a bare shorter verdict is still a no-op on it.
_kept2="$(_posture_get or down 2>/dev/null)"
_lane_down_mark or
[ "$(_posture_get or down 2>/dev/null)" = "$_kept2" ] && [ "$(cat "$OSRC_POSTURE_DIR/or.down-reason" 2>/dev/null)" = "plan quota exhausted" ] && ok "reset: bare re-mark still no-ops on the reasoned window" || bad "reset: bare re-mark clobbered the reasoned mark"

# ---- evidence hygiene (stored value must be one line, secret-free, valid UTF-8) ----
# Multi-line evidence folds to ONE line: a raw newline would let stored evidence forge extra
# rows in `posture status` (which cats these files raw), or a second fake "marker" line.
_lane_down_mark gm 300 "plan limit exhausted" "$(printf 'line one\nline two\ttabbed\r\nend')"
_ev="$(cat "$OSRC_POSTURE_DIR/gm.down-evidence")"
printf '%s' "$_ev" | grep -q 'line one' && printf '%s' "$_ev" | grep -q 'end' && [ "$(printf '%s' "$_ev" | wc -l | tr -d ' ')" = "0" ] && ok "sanitize: multi-line evidence stored as one line" || bad "sanitize: multi-line evidence mangled ($_ev)"
# Invalid UTF-8 input is kept in sanitized form (not dropped): under a UTF-8 locale BSD sed used
# to abort on the bad byte and the evidence vanished entirely.
_lane_down_mark gm 300 "plan limit exhausted" "$(printf 'bad\xffrawbytes')"
_ev="$(cat "$OSRC_POSTURE_DIR/gm.down-evidence")"
[ -n "$_ev" ] && printf '%s' "$_ev" | grep -q 'badrawbytes' && ok "sanitize: invalid-UTF-8 evidence kept (bad byte dropped)" || bad "sanitize: invalid-UTF-8 evidence lost ($_ev)"
# A 3-byte character straddling the 400-byte cap leaves no partial sequence at the tail.
_pad="$(printf '%*s' 398 '' | tr ' ' 'a')"
_lane_down_mark gm 300 "plan limit exhausted" "${_pad}"$'\xe2\x82\xac'"tail"
_ev="$(cat "$OSRC_POSTURE_DIR/gm.down-evidence")"
[ "$(printf '%s' "$_ev" | wc -c | tr -d ' ')" = "398" ] && [ "$_ev" = "$_pad" ] && ok "sanitize: cap drops a straddling 3-byte char cleanly" || bad "sanitize: cap left a partial sequence (len $(printf '%s' "$_ev" | wc -c | tr -d ' '))"
# Token-shaped evidence is redacted on the way in (evidence is quoted provider stderr).
_lane_down_mark gm 300 "plan limit exhausted" "denied with key sk-abcdef0123456789 embedded"
_ev="$(cat "$OSRC_POSTURE_DIR/gm.down-evidence")"
case "$_ev" in *"sk-abcdef0123456789"*) bad "sanitize: raw token survived into evidence" ;; *"REDACTED"*) ok "sanitize: token-shaped evidence redacted" ;; *) bad "sanitize: unexpected evidence ($_ev)" ;; esac
# ANSI colouring still cannot reach the stored value.
_lane_down_mark gm 300 "plan limit exhausted" "$(printf '\033[31mred\033[0m word')"
_ev="$(cat "$OSRC_POSTURE_DIR/gm.down-evidence")"
[ "$_ev" = "red word" ] && ok "sanitize: ANSI CSI stripped" || bad "sanitize: ANSI bytes survived ($_ev)"

# ---- expiry purge vs in-flight mark (deterministic losing-order simulation) ----
# The race shape: a purge on a just-expired mark could delete a CONCURRENT mark's fresh
# reason/evidence when aux lands BEFORE .down, because the purge's value-match
# cannot see the in-flight write. Under the .down-first order the fresh .down lands before
# its aux and the purge drops aux only when .down is still absent at re-check. Each step below
# is invoked by hand in the exact losing interleaving -- no sleeps, no real races needed.
_posture_set cx down 1   # the expired mark a purging reader had just read
# B's mark is mid-flight under the new order: .down FIRST, aux still pending.
_fut=$(( $(date +%s) + 600 )); _posture_set cx down "$_fut"
# The purge continues on its stale read: the value-match sees the fresh value and must keep all.
_lane_down_purge_expired cx 1
[ "$(_posture_get cx down 2>/dev/null)" = "$_fut" ] && ok "race: stale purge keeps the fresh .down" || bad "race: purge deleted the fresh .down"
# B completes: aux lands after .down.
_posture_set cx down-reason "plan limit exhausted"; _posture_set cx down-evidence "resets in 10m"
_lane_down_active cx && ok "race: fresh mark still down after the interleaved purge" || bad "race: fresh mark lost"
[ "$(cat "$OSRC_POSTURE_DIR/cx.down-reason" 2>/dev/null)" = "plan limit exhausted" ] && [ "$(cat "$OSRC_POSTURE_DIR/cx.down-evidence" 2>/dev/null)" = "resets in 10m" ] && ok "race: aux files intact under the live mark" || bad "race: aux deleted under a live mark"
# The other branch of the same gate: a purge while .down is genuinely absent drops stale aux
# (covers a clear/reset landing mid-mark too -- aux can never outlive its mark).
_posture_set cx down-reason "stale"; _posture_set cx down-evidence "stale"; rm -f "$OSRC_POSTURE_DIR/cx.down"
_lane_down_purge_expired cx 1
[ ! -e "$OSRC_POSTURE_DIR/cx.down-reason" ] && [ ! -e "$OSRC_POSTURE_DIR/cx.down-evidence" ] && ok "race: stale aux purged when .down absent" || bad "race: orphan aux left behind"
# And the ordinary expired purge still removes all three together.
_posture_set cx down 1; _posture_set cx down-reason "stale"; _posture_set cx down-evidence "stale"
_lane_down_active cx || true
[ ! -e "$OSRC_POSTURE_DIR/cx.down" ] && [ ! -e "$OSRC_POSTURE_DIR/cx.down-reason" ] && [ ! -e "$OSRC_POSTURE_DIR/cx.down-evidence" ] && ok "race: expired mark still purges all three" || bad "race: expired purge incomplete"

# ---- a read FAILURE on an existing marker is not "absent" -------------------------------
# _posture_get can fail for reasons other than absence (unreadable file: permissions or a
# transient I/O error). The purge's aux cleanup must key on the .down file's EXISTENCE, not on
# _posture_get's exit status, or a failing read strips the reason/evidence of a live marker.
_lane_down_mark dvx 300 "reason here" "evidence here"
_exp_val="$(_posture_get dvx down)"
printf '%s\n' "$(( $(date +%s) - 10 ))" > "$OSRC_POSTURE_DIR/dvx.down"   # expired
chmod 000 "$OSRC_POSTURE_DIR/dvx.down"                                   # read now fails; file exists
_lane_down_purge_expired dvx "$_exp_val" 2>/dev/null
if [ -e "$OSRC_POSTURE_DIR/dvx.down-reason" ] && [ -e "$OSRC_POSTURE_DIR/dvx.down-evidence" ]; then
  ok "purge: a failing marker read keeps the aux records of an existing .down"
else
  bad "purge: a failing marker read was treated as absent and stripped aux from a live marker"
fi
chmod 644 "$OSRC_POSTURE_DIR/dvx.down" 2>/dev/null
_lane_down_clear dvx

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
