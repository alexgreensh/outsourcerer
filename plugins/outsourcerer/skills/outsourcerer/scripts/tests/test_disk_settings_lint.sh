#!/usr/bin/env bash
# test_disk_settings_lint.sh -- static check: no test removes disk-policy/settings and carries on
# without writing new floors. Without that file the floors come from the host's real disk, so a
# block that follows decides on whatever the machine happens to have free (reports/osrc-fx-disk-r3.md:
# a 5 GB Mac fell under every default floor mid-suite). A removal passes only when the same line or
# the next one writes the file again (`> .../disk-policy/settings`, or a `settings <home>` helper
# call), or the line ends its subshell (`exit ...)`), restoring the state that subshell started from.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# lint <file...> -> prints "file:line: text" for each removal that writes no floors back.
lint() {
  awk '
    function writes(s) { return s ~ />[[:space:]]*"?[^;&|]*disk-policy\/settings/ || s ~ /(^|[;&(])[[:space:]]*settings[[:space:]]+"/ }
    function flush() { if (pend != "") { if (!writes(cur)) print pend; pend = "" } }
    FNR == 1 { if (pend != "") { print pend; pend = "" } }
    { cur = $0 }
    pend != "" { flush() }
    /^[[:space:]]*#/ { next }
    /rm[[:space:]][^;&|]*disk-policy\/settings/ {
      rest = $0; sub(/.*rm[[:space:]][^;&|]*disk-policy\/settings"?/, "", rest)
      if (writes(rest) || rest ~ /exit[^)]*\)/) next
      pend = FILENAME ":" FNR ": " $0
    }
    END { if (pend != "") print pend }
  ' "$@"
}

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# The check must catch the bad shape and pass the good ones, or it proves nothing.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/.disklint.XXXXXX")" || { echo "FAIL: no scratch dir"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' 'x=1' 'rm -f "$RH/disk-policy/settings"' 'n="$(osrc "$RH" _osrc_disk_reclaim)"' > "$TMP/bad.sh"
printf '%s\n' 'rm -f "$RH/disk-policy/settings"; settings "$RH"' \
  'rm -f "$H/disk-policy/settings"' 'settings "$H" "OSRC_DISK_MIN_GB=0"' \
  'rm -f "$H/disk-policy/settings"; printf "OSRC_DISK_MIN_GB=1\n" > "$H/disk-policy/settings"' \
  '( echo x > "$O/disk-policy/settings"; f; r=$?; rm -f "$O/disk-policy/settings"; exit $r ) && ok y' > "$TMP/good.sh"
[ -n "$(lint "$TMP/bad.sh")" ] && ok "lint flags a removal followed by a floor-dependent call" || bad "lint missed the bad fixture"
out="$(lint "$TMP/good.sh")"; [ -z "$out" ] && ok "lint passes removals that write floors back or end their subshell" || bad "false positive: $out"

out="$(lint "$HERE"/*.sh)"
[ -z "$out" ] && ok "no test removes disk-policy/settings without writing new floors" \
  || { bad "tests remove disk-policy/settings and leave the host's real disk deciding:"; printf '  %s\n' "$out"; }

echo ""
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
