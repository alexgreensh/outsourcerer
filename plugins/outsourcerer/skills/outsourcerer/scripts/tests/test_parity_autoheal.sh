#!/usr/bin/env bash
# Parity self-heal (felt-pain user report): plugin caches are version-pinned, so every plugin
# upgrade deletes the directory an earlier `parity` symlinked to. doctor detected the dead links
# but nothing repaired them, so the delegate silently ran without skills the host believed it had.
# _parity_repair_deadlinks re-pins each DEAD link to its source's current location, choosing the
# NEWEST plugin version that actually contains the skill (real caches carry non-semver `unknown`/hash
# siblings that a naive `tail -1` would wrongly pick) and re-pinning within the link's OWN plugin
# lineage. Pruning of truly-gone links is OPT-IN (`prune` arg): `brief` re-pins only (never deletes on
# the hot path); `doctor --fix` prunes. Wired into `brief` and `doctor --fix`.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "$PWD/.test-parity.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
set --; . "$SRC" >/dev/null 2>&1

# ---- build a rotted Devin skills mirror under a sandbox HOME ------------------------------------
H="$TMP/home"
C="$H/.claude/plugins/cache"
mkdir -p "$H/.config/devin/skills" "$H/.claude/skills/realskill" \
         "$C/mp/myplugin/0.10.0/skills/plugskill" \
         "$C/every/ce/3.21.4/skills/ceplan" "$C/every/ce/unknown" \
         "$C/pa/pluginA/2.0.0/skills/dupskill" "$C/pb/pluginB/9.9.9/skills/dupskill" \
         "$C/py/pluginY/1.0.0/skills/orphan"
touch "$H/.claude/skills/realskill/SKILL.md" \
      "$C/mp/myplugin/0.10.0/skills/plugskill/SKILL.md" \
      "$C/every/ce/3.21.4/skills/ceplan/SKILL.md" \
      "$C/pa/pluginA/2.0.0/skills/dupskill/SKILL.md" \
      "$C/pb/pluginB/9.9.9/skills/dupskill/SKILL.md" \
      "$C/py/pluginY/1.0.0/skills/orphan/SKILL.md"
# rotted plugin link: pointed at a deleted 0.9.0 -> must re-pin to 0.10.0
ln -sfn "$C/mp/myplugin/0.9.0/skills/plugskill" "$H/.config/devin/skills/plugskill"
# THE non-semver repro: link pointed at deleted ce/3.20.0; live version is 3.21.4, and `unknown` (empty)
# sorts LAST under sort -V. A naive tail-1 picks `unknown` and PRUNES a live skill. Must re-pin to 3.21.4.
ln -sfn "$C/every/ce/3.20.0/skills/ceplan" "$H/.config/devin/skills/ceplan"
# lineage: link belonged to pluginA; pluginB ALSO has a `dupskill`. Must re-pin within pluginA.
ln -sfn "$C/pa/pluginA/1.0.0/skills/dupskill" "$H/.config/devin/skills/dupskill"
# NO-HIJACK (step-3 removed): link belonged to pluginX, which is ENTIRELY GONE. pluginY has a same-named
# `orphan` skill. With the old step-3 global fallback this would HIJACK to pluginY; now it must stay DEAD
# on brief (repair-only, no cross-plugin hijack) and be pruned only by doctor --fix.
ln -sfn "$C/px/pluginX/1.0.0/skills/orphan" "$H/.config/devin/skills/orphan"
# dead top-level link: re-resolve to ~/.claude/skills
ln -sfn "/nonexistent/realskill" "$H/.config/devin/skills/realskill"
# truly gone: default(brief) call LEAVES it; prune call removes it
ln -sfn "/gone/ghost" "$H/.config/devin/skills/ghost"
# healthy: leave alone
ln -sfn "$H/.claude/skills/realskill" "$H/.config/devin/skills/healthy"

out="$(HOME="$H" _parity_repair_deadlinks)"   # brief-style: NO prune

# ---- re-pin correctness ------------------------------------------------------------------------
[ -e "$H/.config/devin/skills/plugskill" ] && ok "rotted plugin link re-pinned to a live target" || bad "plugin link still dead"
case "$(readlink "$H/.config/devin/skills/plugskill")" in */0.10.0/*) ok "plugin link re-pinned to newest version" ;; *) bad "plugin link not on newest version" ;; esac
# HIGH-defect regression: non-semver sibling must not cause a live skill to be pruned/mis-picked.
[ -e "$H/.config/devin/skills/ceplan" ] && ok "non-semver sibling: live skill re-pinned, NOT pruned" || bad "REGRESSION: live ceplan pruned/unresolved (unknown-dir bug)"
case "$(readlink "$H/.config/devin/skills/ceplan")" in */3.21.4/*) ok "non-semver sibling: picked 3.21.4 not the empty 'unknown' dir" ;; *) bad "ceplan re-pinned to wrong dir: $(readlink "$H/.config/devin/skills/ceplan")" ;; esac
# lineage: dupskill must re-pin within pluginA (its own lineage), never pluginB
[ -e "$H/.config/devin/skills/dupskill" ] && ok "lineage: dupskill re-pinned to a live target" || bad "dupskill still dead"
case "$(readlink "$H/.config/devin/skills/dupskill")" in *pluginA*) ok "lineage: same-name skill re-pinned within its OWN plugin (not pluginB)" ;; *) bad "lineage hijack: dupskill re-pinned to $(readlink "$H/.config/devin/skills/dupskill")" ;; esac
[ -e "$H/.config/devin/skills/realskill" ] && ok "dead top-level link re-resolved to ~/.claude/skills" || bad "top-level link still dead"
[ -e "$H/.config/devin/skills/healthy" ] && ok "healthy link left untouched" || bad "healthy link was clobbered"

# ---- NO-HIJACK: step-3 removed, so an own-plugin-gone link must NOT be re-pinned to another plugin --
[ -e "$H/.config/devin/skills/orphan" ] && bad "HIJACK: own-plugin-gone link re-pinned to another plugin (step-3 not removed)" || ok "no-hijack: own-plugin-gone link stays DEAD on brief (step-3 removed)"
case "$(readlink "$H/.config/devin/skills/orphan")" in *pluginY*) bad "HIJACK: orphan re-pinned to pluginY" ;; *) ok "no-hijack: orphan link not repointed at pluginY" ;; esac

# ---- prune is OPT-IN: brief-style call must NOT delete the truly-gone links ----------------------
[ -L "$H/.config/devin/skills/ghost" ] && ok "brief-style call leaves truly-gone link (never deletes on hot path)" || bad "brief-style call deleted a link (should not prune)"
printf '%s' "$out" | grep -q 'parity self-heal: re-pinned 4, pruned 0' && ok "brief-style summary: re-pinned 4, pruned 0" || bad "summary wrong: [$out]"
# SIGNAL (observability): brief left unrepairable dead links (ghost + orphan) -> one advisory line.
printf '%s' "$out" | grep -q 'dead skill link(s) not repaired on the hot path' && ok "brief signals unrepaired dead links + points at doctor --fix" || bad "no hot-path advisory printed: [$out]"

# ---- explicit prune (doctor --fix / parity) removes ALL truly-gone links (ghost + orphan) --------
out_p="$(HOME="$H" _parity_repair_deadlinks prune)"
[ -L "$H/.config/devin/skills/ghost" ] && bad "prune call did NOT remove the truly-gone ghost link" || ok "prune call removes the truly-gone ghost link"
[ -L "$H/.config/devin/skills/orphan" ] && bad "prune call did NOT remove the own-plugin-gone orphan link" || ok "prune call removes the own-plugin-gone orphan link"
printf '%s' "$out_p" | grep -q 'pruned 2' && ok "prune summary reports pruned 2 (ghost + orphan)" || bad "prune summary wrong: [$out_p]"

# ---- healthy mirror is a silent no-op (zero added tokens on brief's hot path) -------------------
out2="$(HOME="$H" _parity_repair_deadlinks)"
[ -z "$out2" ] && ok "healthy mirror -> silent no-op (no output)" || bad "healthy mirror printed: [$out2]"

# ---- never fatal ------------------------------------------------------------------------------
( HOME="$H" _parity_repair_deadlinks >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "returns 0 (never fatal)" || bad "non-zero return $rc"

# ---- wiring: brief re-pins (no prune) every session; doctor --fix prunes ------------------------
# NOTE: capture awk output into a var before grepping — `grep -q` exits on first match and closes the
# pipe; under `set -o pipefail` that SIGPIPEs awk and fails the pipeline even though the match is real.
grep -q '_parity_repair_deadlinks' "$SRC" && ok "helper defined in source" || bad "helper missing"
brief_body="$(awk '/^cmd_brief\(\)/{p=1} p{print} p&&/^}/{exit}' "$SRC")"
case "$brief_body" in *_parity_repair_deadlinks*) ok "brief auto-heals the mirror" ;; *) bad "brief does not call the heal" ;; esac
case "$brief_body" in *"_parity_repair_deadlinks prune"*) bad "brief PRUNES on the hot path (must be re-pin-only)" ;; *) ok "brief does not pass prune (re-pin-only hot path)" ;; esac
grep -q 'OSRC_BRIEF_NO_HEAL' "$SRC" && ok "brief heal has an opt-out (OSRC_BRIEF_NO_HEAL)" || bad "no opt-out for brief heal"
doctor_body="$(awk '/^doctor\(\)/{p=1} p{print} p&&/^}/{exit}' "$SRC")"
case "$doctor_body" in *--fix*) ok "doctor --fix parsed" ;; *) bad "doctor --fix not wired" ;; esac
case "$doctor_body" in *"_parity_repair_deadlinks prune"*) ok "doctor --fix prunes (explicit repair)" ;; *) bad "doctor --fix does not pass prune" ;; esac
grep -q 'doctor --fix' "$SRC" && ok "doctor advisory points at --fix as the repair" || bad "doctor advisory not updated"

# ---- heal must NOT create net-new links (repair-only, not a silent full parity) -----------------
before="$(ls -1 "$H/.config/devin/skills" | wc -l | tr -d ' ')"
mkdir -p "$H/.claude/skills/brandnew"; touch "$H/.claude/skills/brandnew/SKILL.md"
HOME="$H" _parity_repair_deadlinks >/dev/null
after="$(ls -1 "$H/.config/devin/skills" | wc -l | tr -d ' ')"
[ "$before" = "$after" ] && ok "heal does not add net-new links (that stays \`parity\`'s job)" || bad "heal added net-new links ($before -> $after)"

# ---- source-level: step-3 global fallback removed + cap present ----------------------------------
heal_body="$(awk '/^_parity_repair_deadlinks\(\)/{p=1} p{print} p&&/^}/{exit}' "$SRC")"
case "$heal_body" in *'for plug in "$pcache"/*/*/'*) bad "step-3 global cross-plugin search still present in heal (hijack + O(N*M) perf)" ;; *) ok "step-3 global cross-plugin search removed from heal" ;; esac
case "$heal_body" in *'OSRC_BRIEF_HEAL_MAX'*) ok "hot-path repair cap present (OSRC_BRIEF_HEAL_MAX)" ;; *) bad "no repair cap on the hot path" ;; esac
case "$heal_body" in *'"$pcache"/*/skills/'*) ok "lineage anchored to the real cache root (\$pcache), not a loose */plugins/cache/*" ;; *) bad "lineage case not anchored to \$pcache" ;; esac

# ---- behavioural: cap bounds the hot path; explicit prune (doctor --fix) is unbounded ------------
CH="$TMP/caphome"; CC="$CH/.claude/plugins/cache"; CD="$CH/.config/devin/skills"
mkdir -p "$CD"
for i in 1 2 3 4; do
  mkdir -p "$CC/mp/cap$i/2.0.0/skills/cap$i"; touch "$CC/mp/cap$i/2.0.0/skills/cap$i/SKILL.md"
  ln -sfn "$CC/mp/cap$i/1.0.0/skills/cap$i" "$CD/cap$i"   # dead: points at a deleted 1.0.0
done
cap_out="$(HOME="$CH" OSRC_BRIEF_HEAL_MAX=2 _parity_repair_deadlinks)"
repinned=0; for i in 1 2 3 4; do [ -e "$CD/cap$i" ] && repinned=$((repinned+1)); done
[ "$repinned" -eq 2 ] && ok "cap: brief handled exactly OSRC_BRIEF_HEAL_MAX=2 dead links, deferred the rest" || bad "cap not enforced (re-pinned $repinned of 4, expected 2)"
printf '%s' "$cap_out" | grep -q '2 more dead skill link(s) not repaired on the hot path' && ok "cap: deferred remainder is signalled with a doctor --fix pointer" || bad "cap deferral not signalled: [$cap_out]"
# prune (doctor --fix) is unbounded: it must finish ALL four regardless of the cap.
HOME="$CH" OSRC_BRIEF_HEAL_MAX=2 _parity_repair_deadlinks prune >/dev/null
allrep=0; for i in 1 2 3 4; do [ -e "$CD/cap$i" ] && allrep=$((allrep+1)); done
[ "$allrep" -eq 4 ] && ok "prune (doctor --fix) ignores the cap and repairs all 4" || bad "prune respected the cap (only $allrep of 4 repaired)"

echo "----"
echo "parity self-heal: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
