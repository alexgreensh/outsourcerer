#!/usr/bin/env bash
# test_parity_hermes.sh — the Hermes reverse bridge must work, and keep working.
#
# Hermes (NousResearch) discovers SKILL.md-format skills from $HERMES_HOME/skills/*/SKILL.md — the
# same format Claude/Devin/Antigravity use. So the correct bridge is a SKILL SYMLINK, not an
# AGENTS.md append (that is codex/droid/cursor). This test proves parity-hermes:
#   1) creates a resolvable symlink into $HERMES_HOME/skills that reaches a real SKILL.md,
#   2) is idempotent (re-running is a no-op, not a duplicate/failure),
#   3) self-heals a dangling link (skill moved/upgraded), like the Devin parity guard,
#   4) is wired into dispatch and the help/usage list.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# --- Source-level wiring: the command must exist and be dispatchable + documented. ---
grep -q 'parity-hermes) parity_hermes' "$SRC" \
  && ok "parity-hermes is wired into the subcommand dispatch" \
  || bad "parity-hermes is not dispatched"
grep -q 'parity_hermes()' "$SRC" \
  && ok "parity_hermes() is defined" \
  || bad "parity_hermes() function missing"
grep -q 'parity-hermes; providers' "$SRC" \
  && ok "parity-hermes appears in the usage/unknown-subcommand list" \
  || bad "parity-hermes missing from usage list"

# --- Behavioural: run it against an isolated fake HERMES_HOME + fake skill root. ---
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A fake skill root that looks like an install (has SKILL.md), reached via a fake SCRIPT_PATH so the
# self-locating logic resolves to it: $SCRIPT_PATH -> <root>/scripts/outsourcerer.sh, root = <skill>.
skill="$TMP/install/skills/outsourcerer"
mkdir -p "$skill/scripts"
: > "$skill/SKILL.md"
cp "$SRC" "$skill/scripts/outsourcerer.sh"        # a real, runnable copy (self-locates to $skill)
chmod +x "$skill/scripts/outsourcerer.sh"

hhome="$TMP/hermeshome"                            # HERMES_HOME with no skills dir yet

# First run: must create the dir and a resolvable link.
HERMES_HOME="$hhome" bash "$skill/scripts/outsourcerer.sh" parity-hermes >/dev/null 2>&1
link="$hhome/skills/outsourcerer"
{ [ -L "$link" ] && [ -f "$link/SKILL.md" ]; } \
  && ok "first run creates a symlink that resolves to a real SKILL.md" \
  || bad "first run did not produce a resolvable skill symlink"

# Idempotent: a second run leaves exactly one resolvable link, exit 0.
if HERMES_HOME="$hhome" bash "$skill/scripts/outsourcerer.sh" parity-hermes >/dev/null 2>&1; then
  { [ -L "$link" ] && [ -f "$link/SKILL.md" ]; } \
    && ok "second run is idempotent (still one resolvable link, exit 0)" \
    || bad "second run broke the link"
else
  bad "second run exited non-zero (not idempotent)"
fi

# Self-heal: point the link at a now-deleted target (dangling), then re-run — it must repoint.
rm -f "$link"
ln -sfn "$TMP/gone/skills/outsourcerer" "$link"    # dangling on purpose
{ [ -L "$link" ] && [ ! -e "$link" ]; } \
  && ok "fixture reproduces a dangling link (target does not exist)" \
  || bad "could not build a dangling-link fixture"
HERMES_HOME="$hhome" bash "$skill/scripts/outsourcerer.sh" parity-hermes >/dev/null 2>&1
[ -f "$link/SKILL.md" ] \
  && ok "parity-hermes self-heals a dangling link (repoints at the live skill)" \
  || bad "parity-hermes did not repair the dangling link"

# Real-directory collision: `ln -sfn TARGET dst` where dst is a REAL dir does NOT replace it — it
# nests a link INSIDE (dst/outsourcerer) and returns success, silently no-opping the bridge while
# reporting "linked". parity-hermes must REFUSE this (rc != 0), never nest, never falsely succeed.
rm -f "$link"
mkdir -p "$link/somefile.d"; : > "$link/real-marker"      # a genuine directory occupies the slot
if HERMES_HOME="$hhome" bash "$skill/scripts/outsourcerer.sh" parity-hermes >/dev/null 2>&1; then
  bad "parity-hermes falsely succeeded over a real directory (nested-link bug not guarded)"
else
  { [ -f "$link/real-marker" ] && [ ! -L "$link" ] && [ ! -e "$link/outsourcerer" ]; } \
    && ok "parity-hermes refuses a real-directory destination (no nest, no clobber, no false success)" \
    || bad "parity-hermes mishandled a real-directory destination"
fi
rm -rf "$link"

# Launcher-symlink resolution: invoke the script through a PATH-style symlink (~/.local/bin/outsourcerer
# -> <skill>/scripts/outsourcerer.sh). The self-locator must resolve the physical target and still
# find the skill root, not fall back and mislink. (Regression guard for the command -v $0 case.)
bindir="$TMP/bin"; mkdir -p "$bindir"
ln -sfn "$skill/scripts/outsourcerer.sh" "$bindir/outsourcerer"
hhome2="$TMP/hermeshome2"
HERMES_HOME="$hhome2" bash "$bindir/outsourcerer" parity-hermes >/dev/null 2>&1
link2="$hhome2/skills/outsourcerer"
{ [ -L "$link2" ] && [ -f "$link2/SKILL.md" ]; } \
  && ok "parity-hermes resolves a launcher symlink and links the real skill root" \
  || bad "parity-hermes mislinked when invoked through a launcher symlink"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
