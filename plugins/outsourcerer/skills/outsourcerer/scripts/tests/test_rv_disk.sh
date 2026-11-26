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

echo "=== F13: cleanup <id> refuses before it kills; fanout reports per member ==="
mkwt "$R" job-live; printf 'wip\n' > "$R/.outsourcerer/worktrees/job-live/wip.txt"
sleep 300 </dev/null >/dev/null 2>&1 & LP=$!; KILL="$KILL $LP"; echo "$LP" > "$OSRC_JOBS_T/job-live/pid"; echo running > "$OSRC_JOBS_T/job-live/status"
o="$(run cleanup job-live 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q REFUSING <<<"$o" && kill -0 "$LP" 2>/dev/null \
  && ok "a running dirty lane is refused and left running" || bad "running lane killed or not refused (rc=$rc): $o"
o="$(run cleanup job-live --force 2>&1)"; rc=$?
sleep 0.3; ! kill -0 "$LP" 2>/dev/null && [ "$rc" = 0 ] && ok "--force still stops the lane and removes it" || bad "--force on a live lane (rc=$rc): $o"
mkwt "$R" fo-a; mkwt "$R" fo-b; printf 'wip\n' > "$R/.outsourcerer/worktrees/fo-b/wip.txt"
mkdir -p "$OSRC_HOME/fanout/fo-g"; printf 'fo-a\tA\nfo-b\tB\n' > "$OSRC_HOME/fanout/fo-g/members.tsv"
o="$(run cleanup fo-g 2>&1)"; rc=$?
[ "$rc" != 0 ] && ! grep -q 'cleaned fanout' <<<"$o" && grep -q 'NOT cleaned: fo-b' <<<"$o" \
  && [ ! -d "$R/.outsourcerer/worktrees/fo-a" ] && [ -d "$R/.outsourcerer/worktrees/fo-b" ] \
  && ok "fanout cleanup names the member it kept and fails" || bad "fanout summary (rc=$rc): $o"

echo "=== F14: cleanup --apply keeps a job dir while its worktree is still ASK ==="
mkwt "$R" job-rc; W="$R/.outsourcerer/worktrees/job-rc"; printf 'K=1\n' > "$W/.env"
echo done > "$OSRC_JOBS_T/job-rc/status"
mf() { jq -cn --arg p "$1" --arg k "$2" --arg s "$3" --arg r "$4" '{path:$p,kind:$k,session:$s,repo:$r,ts:1}' >> "$OSRC_HOME/created.jsonl"; }
mf "$OSRC_JOBS_T/job-rc" job job-rc ""; mf "$W" worktree job-rc "$R"
find "$OSRC_JOBS_T/job-rc" "$W" -exec touch -t 202001010000 {} + 2>/dev/null
o="$(run cleanup --apply 2>&1)"
[ -f "$OSRC_JOBS_T/job-rc/worktree.json" ] && [ -d "$W" ] && ok "the job dir and its receipt survive while the worktree is ASK" || bad "receipt deleted with worktree still ASK: $o"
grep -q 'job-rc.*still there' <<<"$(run cleanup 2>&1)" && ok "dry run names why the job dir is kept" || bad "dry run reason missing"
rm -f "$W/.env"; find "$W" -exec touch -t 202001010000 {} + 2>/dev/null
o="$(run cleanup --apply 2>&1)"
[ ! -d "$W" ] && [ ! -d "$OSRC_JOBS_T/job-rc" ] && ok "once the worktree is SAFE both go in one apply" || bad "after SAFE: wt=$([ -d "$W" ] && echo kept) job=$([ -d "$OSRC_JOBS_T/job-rc" ] && echo kept): $o"

echo "=== F15: an early match on a big listing is still a match (no SIGPIPE fail-open) ==="
o="$(osrc "_waited_ids() { printf 'job-w\\n'; seq 1 300000; }; ls() { return 1; }; _osrc_job_collected job-w; echo rc=\$?" | tail -1)"
[ "$o" = rc=1 ] && ok "a waited job early in a long wait list is not collected" || bad "waited job read as collected: $o"
o="$(osrc "git() { if [ \"\$3\" = worktree ]; then printf 'branch refs/heads/br-x\\n'; seq 1 300000; else command git \"\$@\"; fi; }; _osrc_branch_checked_out /nowhere br-x; echo rc=\$?" | tail -1)"
[ "$o" = rc=0 ] && ok "a branch early in a long worktree list is checked out" || bad "checked-out branch missed: $o"

echo "=== F16: a resume whose pause time cannot be banked does not leave the job reading as paused ==="
lstart() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g'; }
stopped() { case "$(ps -o stat= -p "$1" 2>/dev/null)" in *T*) return 0 ;; esac; return 1; }
fakejob() { # <id> -> running job whose delegate is a real sleep; prints its pid
  local jd="$OSRC_JOBS_T/$1" p
  mkdir -p "$jd"; sleep 300 </dev/null >/dev/null 2>&1 & p=$!; KILL="$KILL $p"
  echo running > "$jd/status"; echo "$p" > "$jd/pid"; lstart "$p" > "$jd/pid_start"; printf '%s' "$p"
}
J=job-f16; P="$(fakejob "$J")"; JD="$OSRC_JOBS_T/$J"
osrc "_osrc_disk_pause_job \"$JD\"" >/dev/null
stopped "$P" && ok "setup: the delegate is SIGSTOPped" || bad "setup: delegate not stopped"
sed "s/^since|.*/since|$(( $(date +%s) - 100 ))/" "$JD/disk-paused" > "$JD/rec.tmp" && mv "$JD/rec.tmp" "$JD/disk-paused"
mkdir "$JD/disk-paused-secs"   # the bank write fails, as on a full disk
osrc "_osrc_disk_resume_rec \"$JD/disk-paused\"" >/dev/null
o="$(osrc "_osrc_disk_target_paused $J && echo paused; _osrc_disk_paused_secs \"$JD\"")"
! stopped "$P" && [ ! -f "$JD/disk-paused" ] && ! grep -q paused <<<"$o" && [ "${o:-0}" -ge 100 ] \
  && ok "resumed, not reported paused, the 100s span still counted ($o)" || bad "bank-lost resume: rec=$([ -f "$JD/disk-paused" ] && echo kept) out=$o"
rmdir "$JD/disk-paused-secs"
osrc "_osrc_disk_pause_job \"$JD\"; _osrc_disk_resume_rec \"$JD/disk-paused\"" >/dev/null
o="$(osrc "_osrc_disk_paused_secs \"$JD\"")"
[ "$(cat "$JD/disk-paused-secs" 2>/dev/null)" -ge 100 ] && [ "$o" -ge 100 ] && [ "$o" -lt 200 ] \
  && [ -z "$(ls "$JD" | grep unbanked)" ] && ok "the next bank folds the span in once ($o)" || bad "next bank: secs=$(cat "$JD/disk-paused-secs" 2>/dev/null) total=$o files=$(ls "$JD")"

echo "=== F20: supervise trusts a pause record only while its process is really stopped ==="
svk() { osrc "SCRIPT_PATH=x; _sv_observe $1 \$(date +%s) >/dev/null 2>&1; echo \"k=\$SV_K\"" | tail -1; }
J=job-f20; P="$(fakejob "$J")"; JD="$OSRC_JOBS_T/$J"
osrc "_osrc_disk_pause_job \"$JD\"" >/dev/null
sed "s/^since|.*/since|$(( $(date +%s) - 120 ))/" "$JD/disk-paused" > "$JD/rec.tmp" && mv "$JD/rec.tmp" "$JD/disk-paused"
[ "$(svk $J)" = k=disk-paused ] && [ -f "$JD/disk-paused" ] && ok "a really stopped lane is reported disk-paused" || bad "stopped lane not disk-paused"
kill -CONT "$P"   # the record now lies: e.g. a monitor killed mid-resume
o="$(svk $J)"
[ "$o" != k=disk-paused ] && [ ! -f "$JD/disk-paused" ] && ! stopped "$P" \
  && ok "a stale record is dropped and the lane's real state is read ($o)" || bad "stale record trusted: $o rec=$([ -f "$JD/disk-paused" ] && echo kept)"
J=job-f20b; P="$(fakejob "$J")"; JD="$OSRC_JOBS_T/$J"
printf 'since|%s\nproc|d|%s|0|%s\n' "$(date +%s)" "$P" "$(osrc "_pid_start_identity $P")" > "$JD/disk-paused"
[ "$(svk $J)" = k=disk-paused ] && [ -f "$JD/disk-paused" ] && ok "a record younger than the grace (pause in progress) is trusted" || bad "fresh record dropped"
J=job-f20c; mkdir -p "$OSRC_JOBS_T/$J"; echo running > "$OSRC_JOBS_T/$J/status"
printf 'since|%s\nproc|d|%s|0|gone\n' "$(( $(date +%s) - 120 ))" "$(osrc_test_dead_pid)" > "$OSRC_JOBS_T/$J/disk-paused"
o="$(svk $J)"; [ "$o" != k=disk-paused ] && [ ! -f "$OSRC_JOBS_T/$J/disk-paused" ] && ok "a record naming only dead processes is dropped ($o)" || bad "dead-process record trusted: $o"

echo "RESULTS: $pass pass $fail fail"
[ "$fail" -eq 0 ]
