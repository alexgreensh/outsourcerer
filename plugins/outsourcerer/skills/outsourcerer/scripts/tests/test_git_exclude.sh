#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_git_exclude.sh — lib/git-exclude.sh: the .git/info/exclude block the engine writes into a repo.
#   1. fresh repo: the 4-line block appears once, in order, after git's own template lines
#   2. migrated repo: the old single `/.outsourcerer/` line becomes the block in place; other lines kept
#   3. rerun is a no-op (byte-identical, file not rewritten); duplicates collapse to one block
#   4. git add .outsourcerer/guards/x, guards.conf and verify work WITHOUT -f
#   5. lane state under .outsourcerer/ (worktrees/, jobs, anything else) stays ignored by add -A
#   6. loader: the helper resolves when outsourcerer.sh is sourced through a symlink
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
LIB="$HERE/../lib/git-exclude.sh"
[ -f "$LIB" ] || { echo "FAIL: cannot find $LIB"; exit 1; }
bash -n "$LIB" || { echo "FAIL: bash -n lib/git-exclude.sh"; exit 1; }

TMP="$(mktemp -d "${TMPDIR%/}/.test-git-exclude.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export OSRC_HOME="$TMP/state" GIT_CEILING_DIRECTORIES="$TMP" OSRC_HEARTBEAT_DISABLED=1
mkdir -p "$HOME" "$OSRC_HOME"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

BLOCK='/.outsourcerer/*
!/.outsourcerer/guards/
!/.outsourcerer/guards.conf
!/.outsourcerer/verify'
g() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
mkdir -p "$TMP/bin" && ln -s "$SRC" "$TMP/bin/outsourcerer"
# exclude <repo>: run the engine's helper the way callers get it, through the engine's loader.
exclude() { ( OSRC_SOURCED=1 . "$TMP/bin/outsourcerer" >/dev/null 2>&1; _osrc_git_exclude_state "$1" ); }
block_count() { grep -cxF '/.outsourcerer/*' "$1"; }
our_lines() { grep -E '^!?/\.outsourcerer/' "$1"; }

# ---- 1. fresh repo ------------------------------------------------------------------------------
R="$TMP/fresh"; mkdir -p "$R" && g init -q "$R"
EX="$R/.git/info/exclude"; before="$(cat "$EX" 2>/dev/null)"
exclude "$R"
[ "$(our_lines "$EX")" = "$BLOCK" ] && ok "fresh: block written once, in order" || bad "fresh: $(cat "$EX")"
case "$(cat "$EX")" in "$before"*) ok "fresh: git's template lines kept on top" ;; *) bad "fresh: template lost" ;; esac
rm -f "$EX"; rmdir "$R/.git/info" 2>/dev/null; exclude "$R"
[ "$(our_lines "$EX")" = "$BLOCK" ] && ok "fresh: works with no info/ dir at all" || bad "no info dir: $(cat "$EX" 2>&1)"

# ---- 2. migrated repo ---------------------------------------------------------------------------
R="$TMP/old"; mkdir -p "$R" && g init -q "$R"; EX="$R/.git/info/exclude"
printf '# user header\n*.log\n\n# outsourcerer worker worktrees (local, added automatically)\n/.outsourcerer/\n.osrc-msgs/\nbuild-cache/\n' >"$EX"
exclude "$R"
want="$(printf '# user header\n*.log\n\n# outsourcerer worker worktrees (local, added automatically)\n%s\n.osrc-msgs/\nbuild-cache/' "$BLOCK")"
[ "$(cat "$EX")" = "$want" ] && ok "migrated: old line replaced in place, every other line untouched" || bad "migrated:"$'\n'"$(cat "$EX")"
has_old="$(grep -cxF '/.outsourcerer/' "$EX")"
[ "$has_old" = 0 ] && ok "migrated: old single line gone" || bad "old line still there ($has_old)"

# ---- 3. rerun is a no-op; duplicates collapse ---------------------------------------------------
cp "$EX" "$TMP/snap"; ino1="$(ls -i "$EX" | awk '{print $1}')"
exclude "$R"; exclude "$R"
cmp -s "$EX" "$TMP/snap" && ok "rerun: byte-identical" || bad "rerun changed the file:"$'\n'"$(diff "$TMP/snap" "$EX")"
[ "$(ls -i "$EX" | awk '{print $1}')" = "$ino1" ] && ok "rerun: file not rewritten" || bad "rerun rewrote the file"
printf '/.outsourcerer/\n*.tmp\n%s\n/.outsourcerer/\n' "$BLOCK" >>"$EX"
exclude "$R"
[ "$(block_count "$EX")" = 1 ] && [ "$(our_lines "$EX")" = "$BLOCK" ] && ok "duplicates and stray old lines collapse to one block" || bad "dupes:"$'\n'"$(cat "$EX")"
[ "$(grep -cxF '*.tmp' "$EX")" = 1 ] && ok "a user line between duplicates survives" || bad "user line lost"

# ---- 4 + 5. what git add does with the block ----------------------------------------------------
R="$TMP/use"; mkdir -p "$R" && g init -q "$R" && cd "$R" || exit 1
printf '/.outsourcerer/\n' >>.git/info/exclude   # an old-style repo, migrated by the call below
exclude "$R"
mkdir -p .outsourcerer/guards .outsourcerer/worktrees/job1 .outsourcerer/jobs
printf 'exit 0\n' >.outsourcerer/guards/x; printf 'default = observe\n' >.outsourcerer/guards.conf
printf 'make test\n' >.outsourcerer/verify; printf 'a  # reason\n' >.outsourcerer/guards/slop.allow
printf 'wip\n' >.outsourcerer/worktrees/job1/file; printf '{}\n' >.outsourcerer/jobs/state.json
printf 'x\n' >.outsourcerer/lane.lock
add_err="$(g add .outsourcerer/guards/x 2>&1)"; rc=$?
staged="$(g diff --cached --name-only)"
[ "$rc" = 0 ] && [ "$staged" = ".outsourcerer/guards/x" ] && ok "git add .outsourcerer/guards/x works without -f" || bad "add guards/x rc=$rc: $add_err"
g add -A
staged="$(g diff --cached --name-only | sort)"
want="$(printf '.outsourcerer/guards.conf\n.outsourcerer/guards/slop.allow\n.outsourcerer/guards/x\n.outsourcerer/verify')"
[ "$staged" = "$want" ] && ok "add -A stages guards/, guards.conf, verify and nothing else" || bad "add -A staged:"$'\n'"$staged"
for p in .outsourcerer/worktrees/job1/file .outsourcerer/jobs/state.json .outsourcerer/lane.lock; do
  g check-ignore -q "$p" && ok "lane state stays ignored: $p" || bad "not ignored: $p"
done

echo "test_git_exclude: $pass passed, $fail failed"
[ "$fail" = 0 ]
