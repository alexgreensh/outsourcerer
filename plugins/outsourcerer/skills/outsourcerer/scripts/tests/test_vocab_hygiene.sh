#!/usr/bin/env bash
# Track B — vocabulary hygiene: the sanitizer that keeps model-facing text out of the fallback cascade.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "$PWD/.test-vocab.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
set --; . "$SRC" >/dev/null 2>&1

san() { printf '%s' "$1" | _vocab_sanitize; }

# ---- core replacements --------------------------------------------------------------------------
[ "$(san 'the kill switch')" = 'the hold latch' ]        && ok "kill switch -> hold latch"      || bad "kill switch"
[ "$(san 'we hijacked it')" = 'we taken over it' ]       && ok "hijacked -> taken over"          || bad "hijacked"
[ "$(san 'an orphaned worker')" = 'an stray worker' ]    && ok "orphaned -> stray"               || bad "orphaned"
[ "$(san 'killed the tree')" = 'stopped the tree' ]      && ok "killed -> stopped"               || bad "killed"
[ "$(san 'the corpse job')" = 'the stale record job' ]   && ok "corpse -> stale record"          || bad "corpse"
[ "$(san 'blast radius huge')" = 'scope huge' ]          && ok "blast radius -> scope"           || bad "blast radius"

# ---- word boundaries: must NOT mangle words that merely CONTAIN a trigger ------------------------
[ "$(san 'killer whales are skillful')" = 'killer whales are skillful' ] && ok "killer/skillful untouched (boundaries)" || bad "boundary over-match"
[ "$(san 'KILLER instinct')" = 'KILLER instinct' ]       && ok "KILLER untouched (uppercase boundary)"  || bad "uppercase boundary over-match"
[ "$(san 'run the tests')" = 'run the tests' ]           && ok "neutral prose unchanged"         || bad "neutral changed"

# ---- capitalization: lower / Sentence / UPPER all matched (review finding #8) --------------------
[ "$(san 'Killed the job')" = 'Stopped the job' ]        && ok "Sentence-case trigger -> Sentence-case"  || bad "cap not preserved"
[ "$(san 'KILL the HIJACK')" = 'STOP the TAKE OVER' ]    && ok "ALL-CAPS trigger -> ALL-CAPS"            || bad "uppercase not softened"

# ---- adjacent triggers: no trigger left behind (review finding #7) -------------------------------
[ "$(san 'kill kill kill')" = 'stop stop stop' ]         && ok "three adjacent triggers all softened"    || bad "adjacent triggers left behind"
[ "$(san 'orphan orphan')" = 'stray stray' ]             && ok "two adjacent triggers softened"           || bad "adjacent pair left behind"

# ---- default leaves common tech words alone; aggressive softens them -----------------------------
[ "$(san 'the payload was dead')" = 'the payload was dead' ] && ok "default leaves payload/dead alone" || bad "default too aggressive"
[ "$(OSRC_VOCAB_AGGRESSIVE=1 san 'the payload was dead')" = 'the parcel was ended' ] && ok "aggressive softens payload/dead" || bad "aggressive map inert"

# ---- subcommand: dry-run reports, --write applies, source refused --------------------------------
mkdir -p "$TMP/notes"
printf 'The kill switch armed the daemon.\nplain line\n' > "$TMP/notes/decisions.md"
printf 'kill "$pid"  # real syscall, must survive\n'      > "$TMP/notes/run.sh"

out="$(cmd_sanitize "$TMP/notes" 2>&1)"
printf '%s' "$out" | grep -q 'decisions.md:1' && ok "dry-run reports the trigger line" || bad "dry-run missed it"
printf '%s' "$out" | grep -q 'run.sh' && bad "source file was scanned (should be skipped)" || ok "source file skipped in scan"
grep -q 'kill switch' "$TMP/notes/decisions.md" && ok "dry-run wrote nothing" || bad "dry-run mutated the file"

cmd_sanitize "$TMP/notes/decisions.md" --write >/dev/null 2>&1
grep -q 'hold latch' "$TMP/notes/decisions.md" && ok "--write softened the prose file" || bad "--write did not apply"
grep -q 'kill "\$pid"' "$TMP/notes/run.sh" && ok "syscall in .sh preserved (never sanitized)" || bad "source file was mutated"

# refusing a lone source-file target
out2="$(cmd_sanitize "$TMP/notes/run.sh" 2>&1)"
printf '%s' "$out2" | grep -qi 'skipping.*source' && ok "lone source-file target is refused with a note" || bad "source-file target not refused"

# ---- atomic write: a failed rewrite leaves the ORIGINAL intact and is counted as failed (#6/#10) --
mkdir -p "$TMP/ro"
printf 'The kill switch is here.\n' > "$TMP/ro/state.md"
orig="$(cat "$TMP/ro/state.md")"
chmod 500 "$TMP/ro"   # directory not writable -> mktemp/rename in it must fail, original must survive
out3="$(cmd_sanitize "$TMP/ro/state.md" --write 2>&1)"; rc3=$?
chmod 700 "$TMP/ro"
[ "$(cat "$TMP/ro/state.md")" = "$orig" ] && ok "failed rewrite left the original intact (no truncation)" || bad "original was damaged on failed write"
[ "$rc3" -ne 0 ] && ok "sanitize --write returns nonzero when a rewrite fails" || bad "failed rewrite reported success"
printf '%s' "$out3" | grep -qiE 'failed|could not' && ok "failed rewrite is reported, not counted as rewritten" || bad "failed rewrite silently counted"

# ---- regression (gauntlet MAJOR): a filename containing a newline must still be discovered/rewritten -
# find|read split newline-delimited output into two nonexistent paths, silently skipping the file.
mkdir -p "$TMP/nl"
nlf="$TMP/nl/line
break.md"
printf 'kill\n' > "$nlf"
cmd_sanitize --write "$TMP/nl" >/dev/null 2>&1
[ "$(cat "$nlf")" = "stop" ] && ok "newline-in-filename file is sanitized (NUL-delimited traversal)" || bad "newline-in-filename file was silently skipped"

echo "----"
echo "vocab-hygiene: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
