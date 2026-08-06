#!/usr/bin/env bash
# test_parity_links.sh — parity must be able to REPAIR itself.
#
# The failure this guards is the quiet kind. Plugin caches are versioned, so upgrading a plugin
# deletes the version directory an earlier parity run linked to. The old guard treated any symlink as
# "already linked", including a dangling one, so parity could never replace it. The skills directory
# stayed full and looked healthy while 38% of its entries pointed at nothing — the delegate ran
# without the skills the host was certain it had. A tool whose parity promise rots silently is worse
# than one that never promised parity, because nobody goes looking.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Source-level: the dangling-link path must be handled explicitly.
grep -q 'dangling: replace, don' "$SRC" \
  && ok "parity replaces a dangling link instead of preserving it" \
  || bad "no dangling-symlink handling in parity"
grep -q 'pruned %s dead link\|pruned $_stale dead link' "$SRC" \
  && ok "parity reports dead links it pruned (rot is announced, not silent)" \
  || bad "dead-link pruning is not reported"

# Behavioural: reproduce the version-bump that broke it, using parity's own linking logic.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
dst="$TMP/skills"; mkdir -p "$dst"
old="$TMP/cache/plug/1.0.0/skills/ce-debug"; mkdir -p "$old"; : > "$old/SKILL.md"
new="$TMP/cache/plug/2.0.0/skills/ce-debug"; mkdir -p "$new"; : > "$new/SKILL.md"

ln -sfn "$old" "$dst/ce-debug"                    # a parity run from before the upgrade
rm -rf "$TMP/cache/plug/1.0.0"                    # the upgrade removes the old version dir
[ -L "$dst/ce-debug" ] && [ ! -e "$dst/ce-debug" ] \
  && ok "fixture reproduces the real state: a symlink that exists but resolves to nothing" \
  || bad "fixture did not produce a dangling link"

# The OLD guard: `[ -e ] || [ -L ] && continue` — this is what shipped, and why it never healed.
skipped=0
{ [ -e "$dst/ce-debug" ] || [ -L "$dst/ce-debug" ]; } && skipped=1
[ "$skipped" = "1" ] \
  && ok "the old guard demonstrably skips a dead link (this is the bug, reproduced)" \
  || bad "could not reproduce the old skip behaviour"

# The NEW guard: only a link that RESOLVES counts as present.
if [ -e "$dst/ce-debug" ]; then :; else
  [ -L "$dst/ce-debug" ] && rm -f "$dst/ce-debug"
  ln -sfn "$new" "$dst/ce-debug"
fi
[ -f "$dst/ce-debug/SKILL.md" ] \
  && ok "the new guard repoints the link at the current version (parity self-heals)" \
  || bad "link still broken after the repair path"

# And a skill genuinely removed upstream must be swept, not left as a convincing corpse.
ln -sfn "$TMP/cache/plug/9.9.9/skills/gone" "$dst/gone"
stale=0
for l in "$dst"/*; do [ -L "$l" ] || continue; [ -e "$l" ] && continue; rm -f "$l"; stale=$((stale+1)); done
{ [ "$stale" -eq 1 ] && [ ! -e "$dst/gone" ] && [ -f "$dst/ce-debug/SKILL.md" ]; } \
  && ok "prune removes only the unresolvable links, leaving live ones intact" \
  || bad "prune removed the wrong thing (stale=$stale)"

# ---- CRITICAL: parity's NET-NEW linker must skip non-semver siblings that carry no skills ---------
# Real caches carry non-semver dirs (`unknown`, content-hash) that sort LAST under _vsort but hold no
# skills/. The old net-new pick (`ls | _vsort | tail -1`) grabbed that empty dir, so a plugin whose
# highest SEMVER version has skills (compound-engineering: 3.21.4 + `unknown`) never got linked. The
# fixed pick walks ascending and keeps the highest version whose skills/ EXISTS.
# Source-level: the net-new block must no longer end on a bare `| _vsort | tail -1` version pick.
parity_body="$(awk '/^parity\(\)/{p=1} p{print} p&&/^}/{exit}' "$SRC")"
case "$parity_body" in
  *'ls -1 "$plug" 2>/dev/null | _vsort | tail -1'*) bad "parity net-new still uses tail -1 (picks empty non-semver dir)" ;;
  *) ok "parity net-new no longer uses the tail -1 pick" ;;
esac
case "$parity_body" in
  *'[ -d "${plug}${_pv}/skills" ] && ver="$_pv"'*) ok "parity net-new keeps the highest version whose skills/ exists" ;;
  *) bad "parity net-new does not use the skills-carrying ascending walk" ;;
esac

# Behavioural: reproduce the exact selection over a compound-engineering-shaped cache and assert the
# SEMVER dir with skills wins over the alphabetically-last empty `unknown`.
# (This test does not source the script, so mirror its _vsort: version sort, letters sort after digits.)
_vsort() { sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n -k4,4n; }
pc="$TMP/pcache/every/ce"; mkdir -p "$pc/3.21.4/skills/ce-plan" "$pc/unknown"
: > "$pc/3.21.4/skills/ce-plan/SKILL.md"
# _vsort orders `3.21.4` before `unknown` (letters sort after digits), so `unknown` is the tail.
sel=""
while IFS= read -r _pv; do
  [ -n "$_pv" ] || continue
  [ -d "$pc/$_pv/skills" ] && sel="$_pv"
done <<EOF
$(ls -1 "$pc" 2>/dev/null | _vsort)
EOF
[ "$sel" = "3.21.4" ] \
  && ok "net-new pick selects 3.21.4 (skills-carrying) over the empty 'unknown' tail" \
  || bad "net-new pick chose '$sel' instead of 3.21.4"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
