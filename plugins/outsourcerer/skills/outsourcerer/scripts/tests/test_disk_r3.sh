#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_disk_r3.sh -- worktree deletion is guarded at the moment it happens (lane osrc-fx-disk-r3).
# `git worktree remove` without --force still deletes IGNORED files, so every path that removes a
# worktree goes through _osrc_wt_remove: it re-reads the untracked and ignored list right before
# the removal and logs the removal before it runs.
#   1. typed `cleanup --apply` deleted a merged worktree whose ignored node_modules/ held a .env
#      (the verdict sees only the collapsed '!! node_modules/' line and calls the cache disposable)
#   2. merged-lane reclaim removed a worktree even when its deletion could not be logged
#   4. two overlapping pause sweeps: the second overwrote the first's record, so the first's
#      SIGSTOPped processes were named by no record and never resumed (a test_disk_policy hang)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR%/}/.diskr3-test.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
export OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0 OSRC_CLEANUP_MIN_AGE=0 OSRC_CLEANUP_LSOF_TIMEOUT=5
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
osrc() { OSRC_HOME="$1" OSRC_SOURCED=1 bash -c '. "$0" >/dev/null 2>&1; eval "$1"' "$SRC" "$2" 2>&1; }
# fixture <name> -> a home (explicit floors, reclaim on) and a repo whose main is "pushed"
fixture() {
  H="$TMP/$1/home"; R="$TMP/$1/repo"; mkdir -p "$H/jobs" "$H/disk-policy" "$R"
  printf 'OSRC_DISK_MIN_GB=10\nOSRC_DISK_PAUSE_GB=4\nOSRC_DISK_CRITICAL_GB=1\n' > "$H/disk-policy/settings"
  ( cd "$R" && git init -q && echo v1 > app.txt && printf '.env\nnode_modules/\n' > .gitignore && git add -A && git commit -qm init \
    && git update-ref refs/remotes/origin/main HEAD )
}
# lane <name> -> a merged lane worktree + branch + receipt, owner done
lane() {
  local wt="$R/.outsourcerer/worktrees/$1"
  git -C "$R" worktree add -q "$wt" -b "outsourcerer/$1" HEAD
  mkdir -p "$H/jobs/$1"; echo done > "$H/jobs/$1/status"
  jq -cn --arg b "outsourcerer/$1" --arg s "$(git -C "$R" rev-parse HEAD)" '{branch:$b,base_sha:$s}' > "$H/jobs/$1/worktree.json"
  jq -cn --arg p "$wt" --arg s "$1" --arg r "$R" '{path:$p,kind:"worktree",session:$s,repo:$r,ts:1}' >> "$H/created.jsonl"
  jq -cn --arg p "outsourcerer/$1" --arg s "$1" --arg r "$R" '{path:$p,kind:"branch",session:$s,repo:$r,ts:1}' >> "$H/created.jsonl"
}

echo "=== 1: typed cleanup --apply never deletes a secret inside an ignored cache ==="
fixture apply; lane secret; lane cache
mkdir -p "$R/.outsourcerer/worktrees/secret/node_modules/pkg"; echo TOKEN=1 > "$R/.outsourcerer/worktrees/secret/node_modules/pkg/.env"
mkdir -p "$R/.outsourcerer/worktrees/cache/node_modules/pkg"; echo 'x' > "$R/.outsourcerer/worktrees/cache/node_modules/pkg/index.js"
OSRC_HOME="$H" bash "$SRC" cleanup --apply >/dev/null 2>&1
[ -f "$R/.outsourcerer/worktrees/secret/node_modules/pkg/.env" ] && ok "worktree with node_modules/pkg/.env kept" || bad "cleanup --apply deleted an ignored .env"
[ ! -d "$R/.outsourcerer/worktrees/cache" ] && ok "a plain dependency cache still goes" || bad "cache-only worktree kept: $(cat "$H/cleanup.log" 2>/dev/null)"
grep -q 'removing-worktree.*worktrees/cache' "$H/cleanup.log" 2>/dev/null && ok "apply logs the removal before it runs" || bad "no pre-removal log: $(cat "$H/cleanup.log" 2>/dev/null)"
grep -q 'worktrees/secret' "$H/cleanup.log" 2>/dev/null && bad "secret worktree reached the removal step" || ok "secret worktree never reached removal"

echo "=== 2: reclaim removes nothing it cannot log first ==="
fixture nolog; lane gone
rm -f "$H/cleanup.log"; mkdir "$H/cleanup.log"   # the log cannot be appended to
n="$(osrc "$H" '_osrc_disk_reclaim')"
[ -d "$R/.outsourcerer/worktrees/gone" ] && [ "$n" = 0 ] && ok "unloggable removal refused" || bad "removed without a log line (n=$n)"
rmdir "$H/cleanup.log"
n="$(osrc "$H" '_osrc_disk_reclaim')"
[ ! -d "$R/.outsourcerer/worktrees/gone" ] && grep -q 'removing-worktree' "$H/cleanup.log" && grep -q 'removed-worktree' "$H/cleanup.log" \
  && ok "with a writable log the same lane is reclaimed, logged before and after" || bad "reclaim after log fix: n=$n $(cat "$H/cleanup.log" 2>/dev/null)"

echo "=== 3: the re-check runs at removal time, not only at scan time ==="
fixture late; lane late
# An ignored file lands after the scan said SAFE (a lane writing .env while reclaim runs).
n="$(osrc "$H" 'items="$(_osrc_cleanup_items --no-size)"; echo TOKEN=1 > "'"$R"'/.outsourcerer/worktrees/late/.env"; _osrc_disk_reclaim "$items"')"
[ -f "$R/.outsourcerer/worktrees/late/.env" ] && ok "ignored file written after the scan is kept" || bad "late .env deleted (n=$n)"

echo "=== 4: overlapping pause sweeps never overwrite each other's record ==="
# Two sweeps both saw no record for a lane; the second listed only the pids the first had not.
# Its write must lose, or the first sweep's SIGSTOPped processes are named by no record.
fixture race; D="$H/disk-policy/paused"; mkdir -p "$D"
sleep 300 & P1=$!; sleep 300 & P2=$!; disown "$P1" "$P2" 2>/dev/null
out="$(osrc "$H" 'A="since|1
proc|d|'"$P1"'|0|$(_pid_start_identity '"$P1"')
"; B="since|2
proc|d|'"$P2"'|0|$(_pid_start_identity '"$P2"')
"
  _osrc_disk_rec_write "$OSRC_HOME/disk-policy/paused/fg-1" "$A"; echo "a=$?"
  _osrc_disk_rec_write "$OSRC_HOME/disk-policy/paused/fg-1" "$B"; echo "b=$?"')"
grep -q 'a=0' <<<"$out" && grep -q 'b=2' <<<"$out" && ok "the second record write reports an existing record" || bad "rec_write: $out"
grep -q "proc|d|$P1|" "$D/fg-1" && ! grep -q "proc|d|$P2|" "$D/fg-1" && ok "the first sweep's record survives intact" || bad "record overwritten: $(cat "$D/fg-1")"
[ -z "$(ls "$D" | grep -v '^fg-1$')" ] && ok "no temp file left behind" || bad "debris: $(ls "$D")"
kill "$P1" "$P2" 2>/dev/null

echo ""
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
