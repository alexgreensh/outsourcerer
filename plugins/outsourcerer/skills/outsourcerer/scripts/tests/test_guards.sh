#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_guards.sh — `outsourcerer guards run` (lib/guards.sh) and the built-in slop, slop-inflation and
# file-size guards. No tmux, no network, no model. Each case builds a throwaway git repo with a `main`
# base and a lane branch.
#   1. every slop class fires on its fixture (slop enforces, slop-inflation observes); clean twins quiet
#   2. guards and guards.conf come from the BASE ref even when the lane edits them; guards_changed set
#   3. observe exits 0 and logs; enforce exits 1; untracked files are part of the diff
#   4. --allow and the 2-block release (blocks counted per distinct diff)
#   5. file-size wraps the base checker and base .file-size-allow; a timed-out guard fails
#   6. false positives: the slop guard is quiet on this module's own real source files
#   7. loader: the command resolves when outsourcerer.sh is reached through a symlink (LOADER.md)
#   R3 review round 1 regressions: M1 state under .outsourcerer is never a guard nor committed;
#      M2 .gitattributes cannot blind the diff; M3 non-ASCII names; M4 renames of guards flagged;
#      M5 unchanged diff / forged count never release; nits (base = own branch, parser, skips, trap)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
LIBDIR="$HERE/../lib"
FIX="$HERE/fixtures/guards"
REPO_TOP="$(cd "$HERE/../../../../../.." && pwd)"
for f in "$SRC" "$LIBDIR/guards.sh" "$LIBDIR/guards/slop.py" "$LIBDIR/guards/file-size.sh" "$LIBDIR/guards/slop-inflation.sh"; do
  [ -f "$f" ] || { echo "FAIL: cannot find $f"; exit 1; }
done
bash -n "$LIBDIR/guards.sh" || { echo "FAIL: bash -n lib/guards.sh"; exit 1; }

TMP="$(mktemp -d "${TMPDIR%/}/.test-guards.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export OSRC_HOME="$TMP/state" GIT_CEILING_DIRECTORIES="$TMP" OSRC_HEARTBEAT_DISABLED=1
unset OSRC_LANE OSRC_GUARDS_BASE
mkdir -p "$HOME" "$OSRC_HOME"
STATE="$OSRC_HOME/guard-state"

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
on_main() { g checkout -q main && "$@" && g checkout -q lane && g merge -q main -m m; }
GUARDS() { bash "$SRC" guards run --base main "$@"; }
jqr() { jq -r "$1" <<<"$2"; }
whats() { jq -r '.failed[].what[]' <<<"$1"; }

# ---- 1. slop classes fire, clean twins do not -------------------------------------------------
new_repo "$TMP/r1"
mkdir -p src node_modules/pkg && cp "$FIX"/slop/* src/ && cp "$FIX"/slop/narration.sh node_modules/pkg/
mkdir -p ok && cp "$FIX"/clean/* ok/ && mkdir -p docs && cp "$FIX/slop/NOTES.md" docs/guide.md
commit_all
out="$(GUARDS --json 2>/dev/null)"; rc=$?
[ "$rc" = 1 ] && ok "default: slop enforces (rc 1)" || bad "default rc=$rc"
what="$(jqr '.failed[] | select(.guard=="slop") | .what[]' "$out")"
for want in "narration src/narration.sh:2" "excuse src/excuse.py:2" \
            "narration src/page.html:2" "excuse src/style.css:1" "markdown src/NOTES.md"; do
  has "$what" "$want" && ok "slop fires: $want" || bad "slop missed: $want"$'\n'"$what"
done
infl="$(jqr '.failed[] | select(.guard=="slop-inflation") | "\(.mode) \(.what[])"' "$out")"
has "$infl" "observe inflation src/inflation.js:1" && ok "slop-inflation fires in observe mode" || bad "inflation: $out"
has "$what" "inflation" && bad "inflation leaked into the enforcing slop guard" || ok "slop guard itself has no inflation hits"
all="$(whats "$out")"
has "$all" "ok/" && bad "clean twin flagged: $(grep 'ok/' <<<"$all")" || ok "clean twins (ok/*) not flagged"
has "$all" "node_modules" && bad "vendored path flagged" || ok "vendored path skipped"
has "$all" "docs/guide.md" && bad "docs/ markdown flagged" || ok "docs/ markdown allowed"
fix="$(jqr '.failed[] | select(.guard=="slop") | .fix' "$out")"
has "$fix" "delete the comment; the commit message carries the why" && ok "FIX message is specific" || bad "fix: $fix"
[ "$(jqr '.mode' "$out")" = enforce ] && [ "$(jqr '.passed' "$out")" = false ] && [ "$(jqr '.guards_changed' "$out")" = false ] \
  && [ "$(jqr '.reviewer_required' "$out")" = false ] && ok "JSON contract: mode/passed/guards_changed/reviewer_required" || bad "JSON contract: $out"
[ "$(jqr '.failed[0] | has("guard") and has("what") and has("fix")' "$out")" = true ] && ok "JSON failed[] items carry guard/what/fix" || bad "failed shape: $out"

# ---- 2. guards come from the base ref ---------------------------------------------------------
new_repo "$TMP/r2"
g checkout -q main
mkdir -p .outsourcerer/guards
cat > .outsourcerer/guards/no-forbidden.sh <<'EOF'
if grep -q '^+.*FORBIDDEN' "$OSRC_GUARD_DIFF"; then
  echo "WHAT: FORBIDDEN token added"; echo "FIX: use the allowed token"; exit 1
fi
exit 0
EOF
printf 'default = enforce\nslop = off\nfile-size = off\n' > .outsourcerer/guards.conf
printf '/.outsourcerer/\n' >> .git/info/exclude   # old-style exclude; the engine's helper migrates it
( OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1; _osrc_git_exclude_state "$TMP/r2" )
g add .outsourcerer && commit_all base-guards && g checkout -q lane && g merge -q --ff-only main
printf 'exit 0\n' > .outsourcerer/guards/no-forbidden.sh
printf 'default = off\n' > .outsourcerer/guards.conf
printf 'FORBIDDEN\n' > code.txt
commit_all
out="$(GUARDS --json 2>/dev/null)"; rc=$?
[ "$rc" = 1 ] && ok "base guard ran despite the lane neutering its copy (rc 1)" || bad "lane copy trusted: rc=$rc $out"
[ "$(jqr '.failed[0].guard' "$out")" = no-forbidden ] && ok "repo guard named in failed[]" || bad "guard name: $out"
[ "$(jqr '.mode' "$out")" = enforce ] && ok "guards.conf read from base (enforce), lane's 'off' ignored" || bad "conf mode: $out"
[ "$(jqr '.guards_changed' "$out")" = true ] && [ "$(jqr '.reviewer_required' "$out")" = true ] && ok "guards_changed + reviewer_required" || bad "guards_changed: $out"
paths="$(jqr '.guards_changed_paths[]' "$out")"
has "$paths" ".outsourcerer/guards/no-forbidden.sh" && has "$paths" ".outsourcerer/guards.conf" \
  && ok "guards_changed_paths lists the edited guard and conf" || bad "paths: $paths"
[ "$(jqr '.skipped | join(",")' "$out")" = "file-size,slop" ] && ok "off guards listed in skipped" || bad "skipped: $out"
[ "$(git ls-files .outsourcerer | sort | tr '\n' ' ')" = ".outsourcerer/guards.conf .outsourcerer/guards/no-forbidden.sh " ] \
  && ok "guards committed with plain git add under the engine's exclude" || bad "tracked: $(git ls-files .outsourcerer)"

# ---- 3. observe vs enforce; untracked files count --------------------------------------------
new_repo "$TMP/r3"
cp "$FIX/slop/NOTES.md" NOTES.md   # untracked, never committed
out="$(GUARDS --mode observe --json 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && ok "observe: rc 0" || bad "observe rc=$rc"
has "$(whats "$out")" "markdown NOTES.md" && ok "untracked NOTES.md is in the diff" || bad "untracked missed: $out"
log="$(cat "$STATE/observe.log" 2>/dev/null)"
has "$log" "slop would-block: markdown NOTES.md" && ok "observe.log (guard-state/) records what would block" || bad "observe.log: $log"
GUARDS --mode enforce >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "enforce: rc 1" || bad "enforce rc=$rc"
GUARDS --mode off --json >"$TMP/off.json" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.ran | length' "$TMP/off.json")" = 0 ] && ok "off: nothing runs, rc 0" || bad "off rc=$rc"
human="$(GUARDS --mode enforce 2>&1)"
has "$human" "FIX: markdown: delete the file unless the brief asked for it" && ok "human output carries FIX" || bad "human: $human"

# ---- 4. --allow and the 2-block release (M5: counted per distinct diff) ------------------------
rm -rf "$STATE/blocks"
run4() { printf 'v%s\n' "$1" >>NOTES.md; GUARDS --mode enforce --lane L4 --json 2>/dev/null; }
run4 1 >/dev/null; r1=$?; run4 2 >/dev/null; r2=$?; out="$(run4 3)"; r3=$?
[ "$r1$r2$r3" = 110 ] && ok "two distinct blocked diffs, the third new diff is released" || bad "release sequence rc=$r1$r2$r3"
[ "$(jqr '.allowed' "$out")" = "allowed after 2 blocks" ] && [ "$(jqr '.passed' "$out")" = true ] \
  && [ "$(jqr '.reviewer_required' "$out")" = true ] && ok "release recorded: allowed + reviewer_required" || bad "release json: $out"
run4 4 >/dev/null; r4=$?
[ "$r4" = 1 ] && ok "count resets after a release" || bad "after release rc=$r4"
rm -rf "$STATE/blocks"
GUARDS --mode enforce --lane M5 >/dev/null 2>&1; a=$?; GUARDS --mode enforce --lane M5 >/dev/null 2>&1; b=$?
GUARDS --mode enforce --lane M5 >/dev/null 2>&1; c=$?; GUARDS --mode enforce --lane M5 >/dev/null 2>&1; d=$?
[ "$a$b$c$d" = 1111 ] && ok "M5: reruns of an unchanged diff never release" || bad "M5 unchanged diff rc=$a$b$c$d"
[ "$(grep -c . "$STATE/blocks/M5")" = 1 ] && ok "M5: an unchanged diff is counted once" || bad "M5 count: $(cat "$STATE/blocks/M5")"
printf '2\n' >"$STATE/blocks/M6"
printf 'v6\n' >>NOTES.md; GUARDS --mode enforce --lane M6 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "M5: a forged count file does not release" || bad "M5 forged count passed"
out="$(GUARDS --mode enforce --lane L5 --allow "brief asked for NOTES.md" --json 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ "$(jqr '.allowed' "$out")" = "brief asked for NOTES.md" ] && [ "$(jqr '.reviewer_required' "$out")" = true ] \
  && ok "--allow passes with its reason, reviewer_required" || bad "--allow rc=$rc $out"
alog="$(cat "$STATE/allowed.log" 2>/dev/null)"
has "$alog" "L5 allowed: brief asked for NOTES.md" && has "$alog" "L4 allowed: allowed after 2 blocks" \
  && ok "allowed.log records both" || bad "allowed.log: $alog"
GUARDS --allow "" >/dev/null 2>&1; [ "$?" = 2 ] && ok "--allow without a reason is a usage error" || bad "empty --allow accepted"

# ---- 5. file-size from base; timeout -----------------------------------------------------------
new_repo "$TMP/r5"
on_main sh -c "mkdir -p scripts && cp '$REPO_TOP/scripts/check_file_size.py' scripts/ && git add -A && git -c user.name=t -c user.email=t@e commit -qm chk"
awk 'BEGIN { for (i = 0; i < 1005; i++) print "echo " i }' > big.sh
printf 'import sys\nsys.exit(0)\n' > scripts/check_file_size.py   # the lane neuters its copy
printf 'big.sh  # lane exempts itself\n' > .file-size-allow
commit_all
out="$(GUARDS --json 2>/dev/null)"
fs="$(jqr '.failed[] | select(.guard=="file-size") | .what[]' "$out")"
has "$fs" "big.sh: new file has 1005 lines" && ok "file-size fires from the base checker, ignoring the lane's .file-size-allow" || bad "file-size: $out"
cp_="$(jqr '.guards_changed_paths[]' "$out")"
has "$cp_" "scripts/check_file_size.py" && has "$cp_" ".file-size-allow" && ok "editing the checker or its allowlist is guards_changed" || bad "checker change: $out"
awk 'BEGIN { for (i = 0; i < 1003; i++) print "echo " i }' > loose.sh   # untracked, never committed
has "$(jqr '.failed[] | select(.guard=="file-size") | .what[]' "$(GUARDS --json 2>/dev/null)")" "loose.sh: new file has 1003 lines" \
  && ok "file-size counts uncommitted files" || bad "uncommitted oversize file passed"
rm -f loose.sh
on_main sh -c "mkdir -p .outsourcerer/guards && printf 'sleep 5\n' > .outsourcerer/guards/slow.sh && git add -A && git -c user.name=t -c user.email=t@e commit -qm slow"
out="$(OSRC_GUARDS_SECS=1 GUARDS --json 2>/dev/null)"
has "$(jqr '.failed[] | select(.guard=="slow") | .what[]' "$out")" "timed out after 1s" && ok "a slow guard times out as a failure" || bad "timeout: $out"

# ---- 6. false positives on real source -------------------------------------------------------
: > "$TMP/self.diff"
for f in "$LIBDIR/guards.sh" "$LIBDIR/guards/slop.py" "$LIBDIR/guards/file-size.sh" "$LIBDIR/git-exclude.sh" "$LIBDIR/done.sh" "$LIBDIR/review.sh"; do
  git diff --no-color --no-index -- /dev/null "$f" >>"$TMP/self.diff" 2>/dev/null
done
sout="$(OSRC_GUARD_DIFF="$TMP/self.diff" python3 -I "$LIBDIR/guards/slop.py")"
hits="$(grep -E '^WHAT: (narration|excuse)' <<<"$sout")"
[ -z "$hits" ] && ok "no narration/excuse hits on lib/guards.sh, slop.py, git-exclude.sh, done.sh, review.sh" || bad "false positives:"$'\n'"$hits"

# ---- S3-1. a repo's base guards.conf can soften or harden the built-ins ------------------------
new_repo "$TMP/s31"
cp "$FIX/slop/narration.sh" n.sh && cp "$FIX/slop/inflation.js" i.js && commit_all
modes() { jqr '[.failed[] | "\(.guard)=\(.mode)"] | sort | join(",")' "$1"; }
conf_on_main() { on_main sh -c "mkdir -p .outsourcerer && printf '$1' > .outsourcerer/guards.conf && git add -f .outsourcerer && git -c user.name=t -c user.email=t@e commit -qm conf"; }
out="$(GUARDS --json 2>/dev/null)"; rc=$?
[ "$rc" = 1 ] && [ "$(modes "$out")" = "slop-inflation=observe,slop=enforce" ] \
  && ok "S3-1: no conf -> built-in defaults (slop enforce, slop-inflation observe)" || bad "S3-1 defaults rc=$rc $(modes "$out")"
conf_on_main 'default = observe\n'
out="$(GUARDS --json 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ "$(modes "$out")" = "slop-inflation=observe,slop=observe" ] \
  && ok "S3-1: 'default = observe' softens the slop built-in (rc 0)" || bad "S3-1 default observe rc=$rc $(modes "$out")"
conf_on_main 'default = observe\nslop = enforce\n'
GUARDS --json >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "S3-1: '<guard> = enforce' beats 'default'" || bad "S3-1 per-guard rc=$rc"
conf_on_main 'slop = off\nslop-inflation = enforce\nfile-size = off\n'
out="$(GUARDS --json 2>/dev/null)"; rc=$?
[ "$rc" = 1 ] && [ "$(modes "$out")" = "slop-inflation=enforce" ] && [ "$(jqr '.skipped | sort | join(",")' "$out")" = "file-size,slop" ] \
  && ok "S3-1: per-guard off/enforce on built-ins" || bad "S3-1 per-guard rc=$rc $out"
conf_on_main 'default = enforce\n'
out="$(GUARDS --json 2>/dev/null)"
[ "$(modes "$out")" = "slop-inflation=enforce,slop=enforce" ] && ok "S3-1: 'default = enforce' hardens slop-inflation" || bad "S3-1 harden: $(modes "$out")"
has "$(bash "$SRC" guards list --base main 2>&1)" "file-size       enforce" && ok "S3-1: guards list shows the repo default on built-ins" || bad "S3-1 list"
GUARDS --mode observe >/dev/null 2>&1; [ "$?" = 0 ] && ok "S3-1: --mode still overrides the conf" || bad "S3-1 --mode"

# ---- 7. through a symlink -----------------------------------------------------------------------
mkdir -p "$TMP/bin" && ln -s "$SRC" "$TMP/bin/outsourcerer"
cd "$TMP/r1" && out="$(bash "$TMP/bin/outsourcerer" guards run --base main --json 2>/dev/null)"
[ "$(jqr '.ran | sort | join(",")' "$out")" = "file-size,slop,slop-inflation" ] && ok "guards run through a symlinked engine" || bad "symlink: $out"
cd "$TMP/r1" && out="$(bash "$TMP/bin/outsourcerer" guards list --base main 2>&1)"
has "$out" "slop            enforce" && has "$out" "slop-inflation  observe" && ok "guards list shows the built-in defaults" || bad "list: $out"
bash "$SRC" guards >/dev/null 2>&1; [ "$?" = 2 ] && ok "bare 'guards' exits 2" || bad "bare guards rc"

# ---- R3 M1: state under OSRC_HOME=<repo>/.outsourcerer is never a guard and never committed ------
new_repo "$TMP/m1"
( OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1; _osrc_git_exclude_state "$TMP/m1" )
on_main sh -c "mkdir -p .outsourcerer/guards && printf 'touch PWNED\n' > .outsourcerer/guards/observe.log && printf 'touch PWNED2\n' > .outsourcerer/guards/notes && git add -f .outsourcerer && git -c user.name=t -c user.email=t@e commit -qm data"
cp "$FIX/slop/inflation.js" m1.js
out="$(OSRC_HOME="$TMP/m1/.outsourcerer" GUARDS --json 2>/dev/null)"
[ ! -e PWNED ] && [ ! -e PWNED2 ] && ok "M1: non-guard files in guards/ (no .sh/.py/#!) never execute" || bad "M1: a data file ran as a guard"
has "$(jqr '.ran | join(",")' "$out")" "observe" && bad "M1: observe.log collected as a guard" || ok "M1: observe.log not collected"
[ -f .outsourcerer/guard-state/observe.log ] && ok "M1: state lands in guard-state/" || bad "M1: no state file"
g check-ignore -q .outsourcerer/guard-state/observe.log && ok "M1: guard-state is git-ignored" || bad "M1: guard-state not ignored"
g add -A; staged="$(g diff --cached --name-only)"
has "$staged" "guard-state" && bad "M1: add -A staged guard state: $staged" || ok "M1: add -A never stages guard state"
g reset -q

# ---- R3 M2: a lane .gitattributes cannot hide a file -----------------------------------------
new_repo "$TMP/m2"
printf '*.sh -diff\n*.py diff=blind\n' > .gitattributes
g config diff.blind.textconv "sed d"
cp "$FIX/slop/narration.sh" n.sh && cp "$FIX/slop/excuse.py" e.py && commit_all
out="$(GUARDS --json 2>/dev/null)"
has "$(whats "$out")" "narration n.sh:2" && ok "M2: -diff attribute does not blind slop" || bad "M2 -diff: $out"
has "$(whats "$out")" "excuse e.py:2" && ok "M2: a textconv driver does not blind slop" || bad "M2 textconv: $out"
has "$(jqr '.guards_changed_paths[]' "$out")" ".gitattributes" && ok "M2: .gitattributes change is guards_changed" || bad "M2 paths: $out"

# ---- R3 M3: non-ASCII file names --------------------------------------------------------------
new_repo "$TMP/m3"
cp "$FIX/slop/narration.sh" "naïve.sh" && commit_all
cp "$FIX/slop/narration.sh" "ünï.sh"   # untracked
w="$(whats "$(GUARDS --json 2>/dev/null)")"
has "$w" "narration naïve.sh:2" && ok "M3: tracked non-ASCII name scanned" || bad "M3 tracked: $w"
has "$w" "narration ünï.sh:2" && ok "M3: untracked non-ASCII name scanned" || bad "M3 untracked: $w"

# ---- R3 M4: renames of guards are flagged -------------------------------------------------------
new_repo "$TMP/m4"
on_main sh -c "mkdir -p .outsourcerer/guards && printf 'exit 0\n' > .outsourcerer/guards/x.sh && printf 'slop = observe\n' > .outsourcerer/guards.conf && git add -f .outsourcerer && git -c user.name=t -c user.email=t@e commit -qm g"
g mv .outsourcerer/guards/x.sh .outsourcerer/guards/y.sh && g mv -f .outsourcerer/guards.conf .outsourcerer/old.conf && g commit -qm mv
p="$(jqr '.guards_changed_paths[]' "$(GUARDS --json 2>/dev/null)")"
has "$p" ".outsourcerer/guards/x.sh" && has "$p" ".outsourcerer/guards/y.sh" && has "$p" ".outsourcerer/guards.conf" \
  && ok "M4: git mv of a guard and of guards.conf is guards_changed" || bad "M4 paths: $p"

# ---- R3 nits ----------------------------------------------------------------------------------
cd "$TMP/m4"
bash "$SRC" guards run --base HEAD >/dev/null 2>&1; a=$?; bash "$SRC" guards run --base lane >/dev/null 2>&1; b=$?
OSRC_GUARDS_BASE=lane bash "$SRC" guards run --base lane >/dev/null 2>&1; c=$?
[ "$a$b$c" = 222 ] && ok "base = HEAD / the lane's own branch is refused (exit 2)" || bad "own-branch base rc=$a$b$c"
new_repo "$TMP/nit"
printf 'let i = 0;\n++ i;\n// Added a retry loop as requested\n' > p.js
printf 'x=1 # quick fix\n' > q.sh
mkdir -p src/build build src/docs && cp "$FIX/slop/narration.sh" src/build/a.sh && cp "$FIX/slop/narration.sh" build/a.sh
cp "$FIX/slop/NOTES.md" src/docs/NOTES.md
commit_all
w="$(whats "$(GUARDS --json 2>/dev/null)")"
has "$w" "narration p.js:3" && ok "an added '++ i;' line is not read as a diff header" || bad "++ line: $w"
has "$w" "excuse q.sh:1" && ok "single-space '# quick fix' trailing comment caught" || bad "single space: $w"
has "$w" "narration src/build/a.sh:2" && ok "nested build/ is scanned" || bad "nested build/: $w"
[ "$(grep -c '^narration build/a.sh' <<<"$w")" = 0 ] && ok "root build/ still skipped" || bad "root build/ scanned"
has "$w" "markdown src/docs/NOTES.md" && ok "nested docs/ markdown is not auto-allowed" || bad "nested docs: $w"
on_main sh -c "printf '/* header\n * text\n */\nfunction a() {}\n' > h.js && git add -A && git -c user.name=t -c user.email=t@e commit -qm h"
printf '/* header v2\n * text\n */\nfunction a() {}\nconst b = 1;\nconst c = 2;\nconst d = 3;\nconst e = 4;\n' > h.js
w="$(whats "$(GUARDS --json 2>/dev/null)")"
has "$w" "h.js" && bad "editing a /* opener counted later code as comments: $w" || ok "context lines keep /* block state in step"
on_main sh -c "mkdir -p .outsourcerer/guards && printf 'exit 0\n' > '.outsourcerer/guards/my guard.sh' && git add -f .outsourcerer && git -c user.name=t -c user.email=t@e commit -qm sp"
has "$(jqr '.ran[]' "$(GUARDS --json 2>/dev/null)")" "my guard" && ok "a guard name with a space stays whole" || bad "space name split"
# trap: a killed run leaves no temp dir behind
mkdir -p "$TMP/tmpd"
on_main sh -c "printf 'sleep 3\n' > .outsourcerer/guards/zz-slow.sh && git add -f .outsourcerer && git -c user.name=t -c user.email=t@e commit -qm slow2"
set -m; TMPDIR="$TMP/tmpd" bash "$SRC" guards run --base main >/dev/null 2>&1 & kpid=$!; set +m
i=0; while [ "$i" -lt 50 ] && [ -z "$(ls "$TMP/tmpd")" ]; do sleep 0.1; i=$((i+1)); done
sleep 0.5; kill -TERM -- "-$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null
i=0; while [ "$i" -lt 50 ] && [ -n "$(ls "$TMP/tmpd" | grep osrc-guards)" ]; do sleep 0.1; i=$((i+1)); done
left="$(ls "$TMP/tmpd" | grep osrc-guards)"
[ -z "$left" ] && ok "a killed run removes its temp dir" || bad "temp dir left behind: $left"

echo "test_guards: $pass passed, $fail failed"
[ "$fail" = 0 ]
