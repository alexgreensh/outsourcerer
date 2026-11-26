#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_rv_disk.sh -- 0.18.0 release-review findings on cleanup and the disk policy (lane
# osrc-fx-rv-disk). Each block names the finding it pins; every assertion fails on the base.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR%/}/.rvdisk-test.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
KILL=""
cleanup_all() {
  local f p
  for f in "$TMP"/*/disk-policy/monitor.lock/owner "$TMP"/osrc/disk-policy/monitor.lock/owner; do
    [ -f "$f" ] && kill "$(cut -d'|' -f1 "$f")" 2>/dev/null
  done
  for p in $KILL; do kill -CONT "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; done
  sleep 0.2; rm -rf "$TMP"
}
trap cleanup_all EXIT
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc" XDG_CONFIG_HOME="$TMP/xdg"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1 OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
export OSRC_DISK_POLICY_POLL=1 OSRC_DISK_MONITOR_IDLE_TICKS=1
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$OSRC_HOME/jobs" "$OSRC_HOME/disk-policy"
printf 'OSRC_DISK_MIN_GB=0\nOSRC_DISK_CRITICAL_GB=0\n' > "$OSRC_HOME/disk-policy/settings"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
run() { bash "$SRC" "$@"; }
osrc() { OSRC_SOURCED=1 bash -c '. "$0" >/dev/null 2>&1; eval "$1"' "$SRC" "$1" 2>&1; }

mkrepo() { # <dir> -> repo with one pushed commit on main
  mkdir -p "$1"; (
    cd "$1" && git init -q && printf 'v1\n' > app.txt && printf '.env\n*.db\nnode_modules/\n' > .gitignore
    git add -A && git commit -qm init && git update-ref refs/remotes/origin/main HEAD
  )
}
mkwt() { # <repo> <id> -> clean worktree on outsourcerer/<id> at main, receipt in jobs/<id>
  git -C "$1" worktree add -q "$1/.outsourcerer/worktrees/$2" -b "outsourcerer/$2" main
  mkdir -p "$OSRC_JOBS_T/$2"
  jq -cn --arg p "$1/.outsourcerer/worktrees/$2" --arg b "outsourcerer/$2" --arg bs "$(git -C "$1" rev-parse main)" \
    '{path:$p,branch:$b,base_sha:$bs}' > "$OSRC_JOBS_T/$2/worktree.json"
}
OSRC_JOBS_T="$OSRC_HOME/jobs"
R="$TMP/repo"; mkrepo "$R"

echo "=== F3: cleanup <id> without --force keeps ignored and hidden-untracked files ==="
mkwt "$R" job-ign; printf 'SECRET=1\n' > "$R/.outsourcerer/worktrees/job-ign/.env"
o="$(run cleanup job-ign 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ -f "$R/.outsourcerer/worktrees/job-ign/.env" ] && [ -f "$OSRC_JOBS_T/job-ign/worktree.json" ] \
  && grep -q 'REFUSING' <<<"$o" && ok "a gitignored .env keeps the worktree (rc=$rc)" || bad "ignored .env removed or not refused (rc=$rc): $o"
mkwt "$R" job-hid; git -C "$R/.outsourcerer/worktrees/job-hid" config status.showUntrackedFiles no
printf 'notes\n' > "$R/.outsourcerer/worktrees/job-hid/notes.txt"
o="$(run cleanup job-hid 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ -f "$R/.outsourcerer/worktrees/job-hid/notes.txt" ] \
  && ok "an untracked file hidden by showUntrackedFiles=no keeps the worktree" || bad "hidden untracked removed (rc=$rc): $o"
o="$(run cleanup job-ign --force 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -d "$R/.outsourcerer/worktrees/job-ign" ] && ok "--force still removes it" || bad "--force broken (rc=$rc): $o"
mkwt "$R" job-cln
o="$(run cleanup job-cln 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -d "$R/.outsourcerer/worktrees/job-cln" ] && ! git -C "$R" rev-parse -q --verify refs/heads/outsourcerer/job-cln >/dev/null \
  && grep -q 'removed-worktree.*job-cln' "$OSRC_HOME/cleanup.log" 2>/dev/null \
  && ok "a clean pushed worktree is removed, and the removal is logged" || bad "clean removal broken (rc=$rc): $o"

echo "=== F11: secret shapes are case-folded and widened; skip-worktree/assume-unchanged edits count ==="
wtr() { osrc "_osrc_wt_remove \"$R\" \"$1\" test ${2:-}; echo rc=\$?" | tail -1; }
for nm in .ENV .envrc prod.env .pypirc cert.PFX keystore.jks id_dsa; do
  mkwt "$R" "wt-s$$"; W="$R/.outsourcerer/worktrees/wt-s$$"
  mkdir -p "$W/node_modules/pkg"; printf 'x\n' > "$W/node_modules/pkg/$nm"
  [ "$(wtr "$W" caches)" = rc=2 ] && [ -f "$W/node_modules/pkg/$nm" ] && ok "cache file $nm keeps the worktree" || bad "cache file $nm deleted"
  git -C "$R" worktree remove --force "$W" >/dev/null 2>&1; git -C "$R" branch -q -D "outsourcerer/wt-s$$"
done
mkwt "$R" wt-sk; W="$R/.outsourcerer/worktrees/wt-sk"
git -C "$W" update-index --skip-worktree app.txt; printf 'edited\n' > "$W/app.txt"
[ "$(wtr "$W")" = rc=2 ] && [ "$(cat "$W/app.txt")" = edited ] && ok "a skip-worktree edit keeps the worktree" || bad "skip-worktree edit deleted"
git -C "$W" update-index --no-skip-worktree app.txt; git -C "$W" checkout -q -- app.txt
git -C "$W" update-index --assume-unchanged app.txt; printf 'edited\n' > "$W/app.txt"
[ "$(wtr "$W")" = rc=2 ] && [ -f "$W/app.txt" ] && ok "an assume-unchanged edit keeps the worktree" || bad "assume-unchanged edit deleted"
printf 'v1\n' > "$W/app.txt"
[ "$(wtr "$W")" = rc=0 ] && [ ! -d "$W" ] && ok "an unchanged assume-unchanged file does not block removal" || bad "unchanged hidden file blocked removal"

echo "=== F12: auto-reclaim never passes a base sha into the --any-ref slot ==="
git -C "$R" branch -q lane-f12 main
o="$(osrc "_osrc_branch_merged() { echo \"argc=\$# \${3:-}\"; return 1; }; _osrc_disk_lane_sha \"$R\" lane-f12 \$(git -C \"$R\" rev-parse main)")"
[ "$o" = "argc=2 " ] && ok "_osrc_disk_lane_sha asks _osrc_branch_merged with repo and branch only" || bad "lane sha passed: $o"

echo "RESULTS: $pass pass $fail fail"
[ "$fail" -eq 0 ]
