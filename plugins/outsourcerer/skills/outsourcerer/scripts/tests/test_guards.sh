#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_guards.sh — `outsourcerer guards run` (lib/guards.sh) and the built-in slop + file-size guards.
# No tmux, no network, no model. Each case builds a throwaway git repo with a `main` base and a lane branch.
#   1. every slop class fires on its fixture; each clean twin and vendored path stays quiet
#   2. guards and guards.conf come from the BASE ref even when the lane edits them; guards_changed set
#   3. observe exits 0 and logs; enforce exits 1; untracked files are part of the diff
#   4. --allow passes with the reason recorded; 2 enforce blocks release the 3rd run, then the count resets
#   5. file-size wraps the base copy of scripts/check_file_size.py; a timed-out guard fails
#   6. false positives: the slop guard is quiet on this module's own real source files
#   7. loader: the command resolves when outsourcerer.sh is reached through a symlink (LOADER.md)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
LIBDIR="$HERE/../lib"
FIX="$HERE/fixtures/guards"
REPO_TOP="$(cd "$HERE/../../../../../.." && pwd)"
for f in "$SRC" "$LIBDIR/guards.sh" "$LIBDIR/guards/slop.py" "$LIBDIR/guards/file-size.sh"; do
  [ -f "$f" ] || { echo "FAIL: cannot find $f"; exit 1; }
done
bash -n "$LIBDIR/guards.sh" || { echo "FAIL: bash -n lib/guards.sh"; exit 1; }

TMP="$(mktemp -d "${TMPDIR%/}/.test-guards.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export OSRC_HOME="$TMP/state" GIT_CEILING_DIRECTORIES="$TMP" OSRC_HEARTBEAT_DISABLED=1
unset OSRC_LANE OSRC_GUARDS_BASE
mkdir -p "$HOME" "$OSRC_HOME"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
has()  { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

g() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }
# new_repo <dir>: main with one commit, lane branch checked out.
new_repo() {
  mkdir -p "$1" && cd "$1" || return 1
  g init -q . && g checkout -q -b main 2>/dev/null
  printf 'base\n' > base.txt
  g add -A && g commit -qm base && g checkout -q -b lane
}
commit_all() { g add -A && g commit -qm "${1:-lane}"; }
GUARDS() { bash "$SRC" guards run --base main "$@"; }
jqr() { jq -r "$1" <<<"$2"; }

# ---- 1. slop classes fire, clean twins do not -------------------------------------------------
new_repo "$TMP/r1"
mkdir -p src node_modules/pkg && cp "$FIX"/slop/* src/ && cp "$FIX"/slop/narration.sh node_modules/pkg/
mkdir -p ok && cp "$FIX"/clean/* ok/ && mkdir -p docs && cp "$FIX/slop/NOTES.md" docs/guide.md
commit_all
out="$(GUARDS --json 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && ok "observe (default) exits 0 with failures" || bad "default observe rc=$rc"
what="$(jqr '.failed[] | select(.guard=="slop") | .what[]' "$out")"
for want in "narration src/narration.sh:2" "excuse src/excuse.py:2" "inflation src/inflation.js:1" \
            "narration src/page.html:2" "excuse src/style.css:1" "markdown src/NOTES.md"; do
  has "$what" "$want" && ok "slop fires: $want" || bad "slop missed: $want"$'\n'"$what"
done
has "$what" "ok/" && bad "clean twin flagged: $(grep 'ok/' <<<"$what")" || ok "clean twins (ok/*) not flagged"
has "$what" "node_modules" && bad "vendored path flagged" || ok "vendored path skipped"
has "$what" "docs/guide.md" && bad "docs/ markdown flagged" || ok "docs/ markdown allowed"
fix="$(jqr '.failed[] | select(.guard=="slop") | .fix' "$out")"
has "$fix" "delete the comment; the commit message carries the why" && ok "FIX message is specific" || bad "fix: $fix"
[ "$(jqr '.mode' "$out")" = observe ] && [ "$(jqr '.passed' "$out")" = true ] && [ "$(jqr '.guards_changed' "$out")" = false ] \
  && ok "JSON contract: mode/passed/guards_changed" || bad "JSON contract: $out"
[ "$(jqr '.failed[0] | has("guard") and has("what") and has("fix")' "$out")" = true ] && ok "JSON failed[] items carry guard/what/fix" || bad "failed shape: $out"

# ---- 2. guards come from the base ref ---------------------------------------------------------
new_repo "$TMP/r2"
cd "$TMP/r2" && g checkout -q main
mkdir -p .outsourcerer/guards
cat > .outsourcerer/guards/no-forbidden.sh <<'EOF'
if grep -q '^+.*FORBIDDEN' "$OSRC_GUARD_DIFF"; then
  echo "WHAT: FORBIDDEN token added"; echo "FIX: use the allowed token"; exit 1
fi
exit 0
EOF
printf 'default = enforce\nslop = off\nfile-size = off\n' > .outsourcerer/guards.conf
printf '/.outsourcerer/\n' >> .git/info/exclude   # the engine excludes it for its worktrees; guards are force-added
g add -f .outsourcerer && commit_all base-guards && g checkout -q lane && g merge -q --ff-only main
printf 'exit 0\n' > .outsourcerer/guards/no-forbidden.sh
printf 'default = off\n' > .outsourcerer/guards.conf
printf 'FORBIDDEN\n' > code.txt
commit_all
out="$(GUARDS --json 2>/dev/null)"; rc=$?
[ "$rc" = 1 ] && ok "base guard ran despite the lane neutering its copy (rc 1)" || bad "lane copy trusted: rc=$rc $out"
[ "$(jqr '.failed[0].guard' "$out")" = no-forbidden ] && ok "repo guard named in failed[]" || bad "guard name: $out"
[ "$(jqr '.mode' "$out")" = enforce ] && ok "guards.conf read from base (enforce), lane's 'off' ignored" || bad "conf mode: $out"
[ "$(jqr '.guards_changed' "$out")" = true ] && ok "guards_changed reported" || bad "guards_changed: $out"
paths="$(jqr '.guards_changed_paths[]' "$out")"
has "$paths" ".outsourcerer/guards/no-forbidden.sh" && has "$paths" ".outsourcerer/guards.conf" \
  && ok "guards_changed_paths lists the edited guard and conf" || bad "paths: $paths"
[ "$(jqr '.skipped | join(",")' "$out")" = "file-size,slop" ] && ok "off guards listed in skipped" || bad "skipped: $out"

# ---- 3. observe vs enforce; untracked files count --------------------------------------------
new_repo "$TMP/r3"
cp "$FIX/slop/NOTES.md" NOTES.md   # untracked, never committed
out="$(GUARDS --mode observe --json 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && ok "observe: rc 0" || bad "observe rc=$rc"
has "$(jqr '.failed[].what[]' "$out")" "markdown NOTES.md" && ok "untracked NOTES.md is in the diff" || bad "untracked missed: $out"
log="$(cat "$OSRC_HOME/guards/observe.log" 2>/dev/null)"
has "$log" "slop would-block: markdown NOTES.md" && ok "observe.log records what would block" || bad "observe.log: $log"
GUARDS --mode enforce >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "enforce: rc 1" || bad "enforce rc=$rc"
GUARDS --mode off --json >"$TMP/off.json" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.ran | length' "$TMP/off.json")" = 0 ] && ok "off: nothing runs, rc 0" || bad "off rc=$rc"
human="$(GUARDS --mode enforce 2>&1)"
has "$human" "FIX: markdown: delete the file unless the brief asked for it" && ok "human output carries FIX" || bad "human: $human"

# ---- 4. --allow and the 2-block release --------------------------------------------------------
rm -f "$OSRC_HOME/guards/blocks/"*
GUARDS --mode enforce --lane L4 >/dev/null 2>&1; r1=$?
GUARDS --mode enforce --lane L4 >/dev/null 2>&1; r2=$?
out="$(GUARDS --mode enforce --lane L4 --json 2>/dev/null)"; r3=$?
[ "$r1$r2$r3" = 110 ] && ok "blocks twice, third run released" || bad "release sequence rc=$r1$r2$r3"
[ "$(jqr '.allowed' "$out")" = "allowed after 2 blocks" ] && [ "$(jqr '.passed' "$out")" = true ] \
  && ok "release recorded in JSON" || bad "release json: $out"
GUARDS --mode enforce --lane L4 >/dev/null 2>&1; r4=$?
[ "$r4" = 1 ] && ok "count resets after a release" || bad "after release rc=$r4"
out="$(GUARDS --mode enforce --lane L5 --allow "brief asked for NOTES.md" --json 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ "$(jqr '.allowed' "$out")" = "brief asked for NOTES.md" ] && ok "--allow passes with its reason" || bad "--allow rc=$rc $out"
alog="$(cat "$OSRC_HOME/guards/allowed.log" 2>/dev/null)"
has "$alog" "L5 allowed: brief asked for NOTES.md" && has "$alog" "L4 allowed: allowed after 2 blocks" \
  && ok "allowed.log records both" || bad "allowed.log: $alog"
GUARDS --allow "" >/dev/null 2>&1; [ "$?" = 2 ] && ok "--allow without a reason is a usage error" || bad "empty --allow accepted"

# ---- 5. file-size from base; timeout -----------------------------------------------------------
new_repo "$TMP/r5"
g checkout -q main && mkdir -p scripts && cp "$REPO_TOP/scripts/check_file_size.py" scripts/ && commit_all add-checker
g checkout -q lane && g merge -q --ff-only main
awk 'BEGIN { for (i = 0; i < 1005; i++) print "echo " i }' > big.sh
printf 'import sys\nsys.exit(0)\n' > scripts/check_file_size.py   # the lane neuters its copy
commit_all
out="$(GUARDS --json 2>/dev/null)"
fs="$(jqr '.failed[] | select(.guard=="file-size") | .what[]' "$out")"
has "$fs" "big.sh: new file has 1005 lines" && ok "file-size fires from the base checker" || bad "file-size: $out"
has "$(jqr '.guards_changed_paths[]' "$out")" "scripts/check_file_size.py" && ok "editing the checker is guards_changed" || bad "checker change: $out"
cd "$TMP/r5" && g checkout -q main && mkdir -p .outsourcerer/guards
printf 'sleep 5\n' > .outsourcerer/guards/slow.sh && commit_all slow && g checkout -q lane && g merge -q main -m m
out="$(OSRC_GUARDS_SECS=1 GUARDS --json 2>/dev/null)"
has "$(jqr '.failed[] | select(.guard=="slow") | .what[]' "$out")" "timed out after 1s" && ok "a slow guard times out as a failure" || bad "timeout: $out"

# ---- 6. false positives on real source -------------------------------------------------------
: > "$TMP/self.diff"
for f in "$LIBDIR/guards.sh" "$LIBDIR/guards/slop.py" "$LIBDIR/guards/file-size.sh" "$LIBDIR/done.sh" "$LIBDIR/review.sh"; do
  git diff --no-color --no-index -- /dev/null "$f" >>"$TMP/self.diff" 2>/dev/null
done
sout="$(OSRC_GUARD_DIFF="$TMP/self.diff" python3 -I "$LIBDIR/guards/slop.py")"
hits="$(grep -E '^WHAT: (narration|excuse)' <<<"$sout")"
[ -z "$hits" ] && ok "no narration/excuse hits on lib/guards.sh, slop.py, done.sh, review.sh" || bad "false positives:"$'\n'"$hits"

# ---- 7. through a symlink -----------------------------------------------------------------------
mkdir -p "$TMP/bin" && ln -s "$SRC" "$TMP/bin/outsourcerer"
cd "$TMP/r1" && out="$(bash "$TMP/bin/outsourcerer" guards run --base main --json 2>/dev/null)"
[ "$(jqr '.ran | join(",")' "$out")" = "file-size,slop" ] && ok "guards run through a symlinked engine" || bad "symlink: $out"
cd "$TMP/r1" && out="$(bash "$TMP/bin/outsourcerer" guards list --base main 2>&1)"
has "$out" "slop" && has "$out" "observe" && ok "guards list" || bad "list: $out"

echo "test_guards: $pass passed, $fail failed"
[ "$fail" = 0 ]
