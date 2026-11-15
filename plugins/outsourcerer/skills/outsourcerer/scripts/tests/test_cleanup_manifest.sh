#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_cleanup_manifest.sh -- the created.jsonl manifest cleanup: dry-run SAFE/ASK
# verdicts, --apply deletes SAFE only, --ack, the disk gate, the scan-only tick,
# and the legacy `cleanup <id> [--force]` worktree path. Every verdict test uses
# the DEFAULT age gate (fixtures are aged on disk); every assertion can fail.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
have_lsof=0; command -v lsof >/dev/null 2>&1 && have_lsof=1

TMP="$(mktemp -d "${TMPDIR%/}/.cleanup-test.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc" XDG_CONFIG_HOME="$TMP/xdg"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1 OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
mkdir -p "$HOME" "$OSRC_HOME" "$XDG_CONFIG_HOME" "$OSRC_HOME/jobs"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

run() { OSRC_HOME="$OSRC_HOME" bash "$SRC" "$@"; }

mkrepo() { # <dir> -> repo with one commit on main
  local d="$1"; mkdir -p "$d"; (
    cd "$d" && git init -q
    printf 'v1\n' > app.txt
    printf '.env\nnode_modules/\nout/\n' > .gitignore
    git add -A; git commit -qm init
  )
}

age() { find "$@" -exec touch -t 202001010000 {} + 2>/dev/null; }
# 2h old: past the default 1h age gate, under the 3d job-evidence TTL.
age2h() {
  local t
  t="$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)"
  find "$@" -exec touch -t "$t" {} + 2>/dev/null
}

manifest() { # <path> <kind> <session> <repo>
  jq -cn --arg p "$1" --arg k "$2" --arg s "$3" --arg r "$4" --argjson t "$(date +%s)" \
    '{path:$p,kind:$k,session:$s,repo:$r,ts:$t}' >> "$OSRC_HOME/created.jsonl"
}

owner() { # <session> [status] -> an owner record that proves the owner existed
  local j="$OSRC_HOME/jobs/$1"
  mkdir -p "$j"; echo "${2:-done}" > "$j/status"; age "$j"
}

echo "=== fixtures ==="
R="$TMP/repo"; mkrepo "$R"

# SAFE worktree+branch: tip == main HEAD, clean tree, an ignored node_modules
# only (disposable cache -> does not block SAFE). Owner has a done job record.
git -C "$R" worktree add -q "$R/.outsourcerer/worktrees/wt-safe" -b outsourcerer/wt-safe HEAD
WT_SAFE="$R/.outsourcerer/worktrees/wt-safe"
mkdir -p "$WT_SAFE/node_modules/pkg"; printf 'module.exports=1\n' > "$WT_SAFE/node_modules/pkg/i.js"
owner wt-safe

# ASK worktree: one commit ahead of main, unmerged.
git -C "$R" worktree add -q "$R/.outsourcerer/worktrees/wt-unmerged" -b outsourcerer/wt-unmerged HEAD
WT_BAD="$R/.outsourcerer/worktrees/wt-unmerged"
( cd "$WT_BAD" && printf 'wip\n' > wip.txt && git add wip.txt && git commit -qm wip )
owner wt-unmerged

# ASK worktree: merged tip but a gitignored .env inside (finding 1).
git -C "$R" worktree add -q "$R/.outsourcerer/worktrees/wt-ignored" -b outsourcerer/wt-ignored HEAD
WT_IGN="$R/.outsourcerer/worktrees/wt-ignored"
printf 'API_KEY=only-copy\n' > "$WT_IGN/.env"
printf 'report\n' > "$WT_IGN/out.md" 2>/dev/null; mkdir -p "$WT_IGN/out" && printf 'report\n' > "$WT_IGN/out/report.md"
owner wt-ignored

# ASK worktree: owner never existed anywhere (finding 5).
git -C "$R" worktree add -q "$R/.outsourcerer/worktrees/ghost-x" -b outsourcerer/ghost-x HEAD
WT_GHOST="$R/.outsourcerer/worktrees/ghost-x"

# B1: status.showUntrackedFiles=no must not hide untracked files — a merged-tip
# worktree with an unseen scratch file is dirty, not deletable.
R2="$TMP/repo2"; mkrepo "$R2"
git -C "$R2" config status.showUntrackedFiles no
git -C "$R2" worktree add -q "$R2/.outsourcerer/worktrees/wt-hidden" -b outsourcerer/wt-hidden HEAD
WT_HID="$R2/.outsourcerer/worktrees/wt-hidden"
printf 'unsaved work\n' > "$WT_HID/scratch.txt"
owner wt-hidden

# B3: dist/build/target are ignored build outputs that can be the lane's own
# deliverable — not disposable caches. A merged worktree holding dist/ is ASK.
printf 'dist/\nbuild/\ntarget/\n' >> "$R/.git/info/exclude"
git -C "$R" worktree add -q "$R/.outsourcerer/worktrees/wt-dist" -b outsourcerer/wt-dist HEAD
WT_DIST="$R/.outsourcerer/worktrees/wt-dist"
mkdir -p "$WT_DIST/dist" "$WT_DIST/target"; printf 'packed deliverable\n' > "$WT_DIST/dist/app.js"
printf 'built\n' > "$WT_DIST/target/bin"
owner wt-dist

# Branch records: pr-hit has a MERGED PR whose headRefOid IS the tip (SAFE);
# pr-old has a MERGED PR but a post-merge commit on top (ASK, finding 2).
git -C "$R" checkout -qb tmp-side
printf 'side\n' > "$R/side.txt"; git -C "$R" add side.txt; git -C "$R" commit -qm side
git -C "$R" branch outsourcerer/pr-old
printf 'side2\n' > "$R/side2.txt"; git -C "$R" add side2.txt; git -C "$R" commit -qm side2
git -C "$R" branch outsourcerer/pr-hit
git -C "$R" checkout -q main
owner job-pr

# gh stub: answers `pr list --head <br> --state merged --json headRefOid`.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
br=""; prev=""
for a in "\$@"; do [ "\$prev" = "--head" ] && br="\$a"; prev="\$a"; done
case "\$br" in
  outsourcerer/pr-hit) git -C "$R" rev-parse outsourcerer/pr-hit 2>/dev/null ;;
  outsourcerer/pr-old) git -C "$R" rev-parse outsourcerer/pr-old~1 2>/dev/null ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# Job dirs. job-old: done, collected, aged -> SAFE. job-busy: done + open file.
# job-uncollected: done but an owner record still points at it -> ASK (finding 4).
mkdir -p "$OSRC_HOME/jobs/job-old"; echo done > "$OSRC_HOME/jobs/job-old/status"
mkdir -p "$OSRC_HOME/jobs/job-busy"; echo done > "$OSRC_HOME/jobs/job-busy/status"; printf 'x\n' > "$OSRC_HOME/jobs/job-busy/f"
mkdir -p "$OSRC_HOME/jobs/job-uncollected"; echo done > "$OSRC_HOME/jobs/job-uncollected/status"
mkdir -p "$OSRC_HOME/owners/sess-x"; : > "$OSRC_HOME/owners/sess-x/job-uncollected"
# job-blocked: terminal-but-not-done evidence, kept until the 3d TTL (finding 4).
mkdir -p "$OSRC_HOME/jobs/job-blocked"; echo blocked > "$OSRC_HOME/jobs/job-blocked/status"
# B4: 'done?' means finished-but-unverified — collected or not, it keeps
# evidence until the TTL just like blocked.
mkdir -p "$OSRC_HOME/jobs/job-unver"; echo 'done?' > "$OSRC_HOME/jobs/job-unver/status"
# B2: loop dirs and autodetach log/rc get the same evidence rule as jobs.
# loop-ok: success + collected -> SAFE. loop-blocked: 2h-old blocked -> ASK.
# loop-uncol: success but an owner record still points at it -> ASK.
mkdir -p "$OSRC_HOME/loops/loop-ok"; echo success > "$OSRC_HOME/loops/loop-ok/state"
mkdir -p "$OSRC_HOME/loops/loop-blocked"; echo blocked > "$OSRC_HOME/loops/loop-blocked/state"
mkdir -p "$OSRC_HOME/loops/loop-uncol"; echo success > "$OSRC_HOME/loops/loop-uncol/state"
mkdir -p "$OSRC_HOME/owners/sess-y"; : > "$OSRC_HOME/owners/sess-y/loop-uncol"
owner loop-ok; owner loop-blocked; owner loop-uncol
# ad-ok: exited 0 -> SAFE. ad-fail: exited 1 -> ASK. ad-noex: session vanished
# with no .rc marker -> ASK.
mkdir -p "$OSRC_HOME/autodetach"
printf 'done\n' > "$OSRC_HOME/autodetach/ad-ok.log"; printf '0\n' > "$OSRC_HOME/autodetach/ad-ok.rc"
printf 'died\n' > "$OSRC_HOME/autodetach/ad-fail.log"; printf '1\n' > "$OSRC_HOME/autodetach/ad-fail.rc"
printf 'hung\n' > "$OSRC_HOME/autodetach/ad-noex.log"
owner ad-ok; owner ad-fail; owner ad-noex
# job-liveowner: remote lane record says live -> ASK.
mkdir -p "$OSRC_HOME/remote"; jq -cn '{id:"job-liveowner",branch:"b",head_ready:false}' > "$OSRC_HOME/remote/job-liveowner.json"
mkdir -p "$OSRC_HOME/jobs/job-liveowner"; echo done > "$OSRC_HOME/jobs/job-liveowner/status"
# Attack lines (finding 5): the jobs dir itself, the owners dir, a '..' path.
mkdir -p "$TMP/outside-dir"

manifest "$WT_SAFE" worktree wt-safe "$R"
manifest "outsourcerer/wt-safe" branch wt-safe "$R"
manifest "$WT_BAD" worktree wt-unmerged "$R"
manifest "outsourcerer/wt-unmerged" branch wt-unmerged "$R"
manifest "$WT_IGN" worktree wt-ignored "$R"
manifest "$WT_GHOST" worktree ghost-x "$R"
manifest "$WT_HID" worktree wt-hidden "$R2"
manifest "$WT_DIST" worktree wt-dist "$R"
manifest "outsourcerer/pr-hit" branch job-pr "$R"
manifest "outsourcerer/pr-old" branch job-pr "$R"
manifest "$OSRC_HOME/jobs/job-old" job job-old ""
manifest "$OSRC_HOME/jobs/job-busy" job job-busy ""
manifest "$OSRC_HOME/jobs/job-uncollected" job job-uncollected ""
manifest "$OSRC_HOME/jobs/job-blocked" job job-blocked ""
manifest "$OSRC_HOME/jobs/job-unver" job job-unver ""
manifest "$OSRC_HOME/jobs/job-liveowner" job job-liveowner ""
manifest "$OSRC_HOME/loops/loop-ok" loop loop-ok ""
manifest "$OSRC_HOME/loops/loop-blocked" loop loop-blocked ""
manifest "$OSRC_HOME/loops/loop-uncol" loop loop-uncol ""
manifest "$OSRC_HOME/autodetach/ad-ok.log" autodetach ad-ok ""
manifest "$OSRC_HOME/autodetach/ad-ok.rc" autodetach ad-ok ""
manifest "$OSRC_HOME/autodetach/ad-fail.log" autodetach ad-fail ""
manifest "$OSRC_HOME/autodetach/ad-fail.rc" autodetach ad-fail ""
manifest "$OSRC_HOME/autodetach/ad-noex.log" autodetach ad-noex ""
manifest "$TMP/outside-dir" job outside-sess ""
manifest "$OSRC_HOME/jobs" job evil ""
manifest "$OSRC_HOME/owners" job evil ""
manifest "$OSRC_HOME/jobs/../remote" job evil ""

age "$WT_SAFE" "$WT_BAD" "$WT_IGN" "$WT_GHOST" "$WT_HID" "$WT_DIST" \
  "$OSRC_HOME/jobs/job-old" "$OSRC_HOME/jobs/job-busy" \
  "$OSRC_HOME/jobs/job-uncollected" "$OSRC_HOME/jobs/job-liveowner" \
  "$OSRC_HOME/loops/loop-ok" "$OSRC_HOME/autodetach/ad-ok.log" \
  "$OSRC_HOME/autodetach/ad-ok.rc"
# job-blocked, the blocked/uncollected loop, and the non-zero/no-marker
# autodetach logs are old enough to pass the 1h gate but young enough that the
# 3d evidence TTL still protects them.
age2h "$OSRC_HOME/jobs/job-blocked" "$OSRC_HOME/jobs/job-unver" "$OSRC_HOME/loops/loop-blocked" \
  "$OSRC_HOME/loops/loop-uncol" "$OSRC_HOME/autodetach/ad-fail.log" \
  "$OSRC_HOME/autodetach/ad-fail.rc" "$OSRC_HOME/autodetach/ad-noex.log"

echo "=== dry run (default age gate) ==="
out="$(run cleanup 2>&1)" || { bad "cleanup dry run failed"; echo "$out"; }
grep -q 'dry run' <<<"$out" && ok "dry run banner" || bad "no dry-run banner: $out"
grep -q "SAFE.*wt-safe" <<<"$out" && ok "merged worktree SAFE despite ignored node_modules" || bad "wt-safe not SAFE: $(echo "$out" | grep wt-safe)"
grep -q "ASK.*wt-unmerged" <<<"$out" && ok "unmerged worktree ASK" || bad "wt-unmerged not ASK"
grep -q "ASK.*wt-ignored" <<<"$out" && ok "worktree with ignored .env ASK (finding 1)" || bad "wt-ignored not ASK"
grep -q "ASK.*ghost-x" <<<"$out" && ok "owner with no record ASK (finding 5)" || bad "ghost-x not ASK"
grep -q "ASK.*wt-hidden" <<<"$out" && ok "hidden untracked file makes worktree ASK (B1)" || bad "wt-hidden not ASK: $(echo "$out" | grep wt-hidden)"
grep -q "ASK.*wt-dist" <<<"$out" && ok "ignored dist/target build output ASK (B3)" || bad "wt-dist not ASK: $(echo "$out" | grep wt-dist)"
grep -q "ignored files in worktree: dist (app.js" <<<"$out" \
  && ok "ASK reason names contents inside an ignored dir (r4)" \
  || bad "ASK reason lacks ignored-dir contents: $(echo "$out" | grep 'ignored files')"
grep -q "ASK.*pr-old" <<<"$out" && ok "merged PR + post-merge commit ASK (finding 2)" || bad "pr-old not ASK"
grep -q "ASK.*job-blocked" <<<"$out" && ok "blocked job keeps evidence until TTL (finding 4)" || bad "job-blocked not ASK"
grep -q "ASK.*job-unver" <<<"$out" && ok "unverified done? job keeps evidence until TTL (B4)" || bad "job-unver not ASK: $(echo "$out" | grep job-unver)"
grep -q "ASK.*job-uncollected" <<<"$out" && ok "done-but-uncollected job ASK (finding 4)" || bad "job-uncollected not ASK"
grep -q "ASK.*outside-dir" <<<"$out" && ok "outside-root path ASK" || bad "outside-dir not ASK"
grep -q "ASK.*job-liveowner" <<<"$out" && ok "live-owner item ASK" || bad "live-owner not ASK"
grep -q "SAFE.*job-old" <<<"$out" && ok "collected done job SAFE" || bad "job-old not SAFE"
grep -q "SAFE.*loop-ok" <<<"$out" && ok "collected success loop SAFE (B2)" || bad "loop-ok not SAFE: $(echo "$out" | grep loop-ok)"
grep -q "ASK.*loop-blocked" <<<"$out" && ok "blocked loop keeps evidence until TTL (B2)" || bad "loop-blocked not ASK"
grep -q "ASK.*loop-uncol" <<<"$out" && ok "success-but-uncollected loop ASK (B2)" || bad "loop-uncol not ASK"
grep -q "SAFE.*ad-ok\.log" <<<"$out" && grep -q "SAFE.*ad-ok\.rc" <<<"$out" \
  && ok "exited-0 autodetach pair SAFE (B2)" || bad "ad-ok not SAFE: $(echo "$out" | grep ad-ok)"
grep -q "ASK.*ad-fail" <<<"$out" && ok "exit-1 autodetach keeps evidence until TTL (B2)" || bad "ad-fail not ASK"
grep -q "ASK.*ad-noex" <<<"$out" && ok "no-exit-marker autodetach keeps evidence until TTL (B2)" || bad "ad-noex not ASK"
{ _t3b_pipe="$(echo "$out" | grep -c "ASK")" && grep -q '^[0-9]' <<<"$_t3b_pipe"; } && grep -q "jobs.*not the shape" <<<"$out" \
  && ok "jobs-dir attack line ASK (finding 5)" || bad "attack lines not ASK: $(echo "$out" | grep -E 'jobs |owners|remote')"
[ -d "$WT_SAFE" ] && [ -d "$WT_BAD" ] && [ -d "$OSRC_HOME/jobs/job-old" ] \
  && ok "dry run deleted nothing" || bad "dry run mutated the filesystem"

echo "=== busy + lsof rc2 (findings 3, 7) ==="
exec 8< "$OSRC_HOME/jobs/job-busy/f"
out2="$(run cleanup 2>&1)"
exec 8<&-
if [ "$have_lsof" = 1 ]; then
  grep -q "ASK.*job-busy.*open" <<<"$out2" && ok "busy dir ASK 'files open'" || bad "busy dir verdict wrong: $(echo "$out2" | grep job-busy)"
else
  grep -q "ASK.*job-busy" <<<"$out2" && ok "no lsof -> cannot-verify ASK" || bad "job-busy not ASK without lsof"
fi
# rc 2 must be ASK, and this assertion can fail (no || true).
v2="$(OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_lsof_busy() { return 2; }
  _osrc_cleanup_verdict "{\"path\":\"'"$OSRC_HOME"'/jobs/job-old\",\"kind\":\"job\",\"session\":\"job-old\",\"repo\":\"\",\"ts\":0}"' 2>&1)"
grep -q '^ASK' <<<"$v2" && ok "lsof cannot-verify lands ASK (finding 3)" || bad "lsof rc2 not ASK: $v2"

echo "=== heartbeat tick scans, never applies (finding 6) ==="
tick="$(OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_free_kb() { printf "51200"; }   # 50MB free -> under every threshold
  _osrc_cleanup_tick_run; echo tick-done' 2>&1)"
grep -q tick-done <<<"$tick" && ok "tick ran" || bad "tick failed: $tick"
[ -f "$OSRC_HOME/cleanup/state.json" ] && ok "tick wrote state.json" || bad "no state.json after tick"
[ -d "$WT_SAFE" ] && [ -d "$OSRC_HOME/jobs/job-old" ] \
  && ok "tick did NOT apply SAFE items" || bad "tick applied deletions under pressure"

echo "=== apply ==="
app="$(run cleanup --apply 2>&1)" || { bad "cleanup --apply failed"; echo "$app"; }
grep -q 'removed' <<<"$app" && ok "apply reported removals" || bad "apply output: $app"
[ ! -d "$WT_SAFE" ] && ok "SAFE worktree removed" || bad "SAFE worktree still present"
git -C "$R" rev-parse --verify -q refs/heads/outsourcerer/wt-safe >/dev/null 2>&1 \
  && bad "SAFE branch survived apply" || ok "merged branch deleted"
git -C "$R" rev-parse --verify -q refs/heads/outsourcerer/pr-hit >/dev/null 2>&1 \
  && bad "tip-matched merged-PR branch survived" || ok "PR-tip-matched branch deleted (finding 2)"
git -C "$R" rev-parse --verify -q refs/heads/outsourcerer/pr-old >/dev/null 2>&1 \
  && ok "post-merge-commit branch preserved (finding 2)" || bad "pr-old branch was deleted!"
[ ! -d "$OSRC_HOME/jobs/job-old" ] && ok "collected done job dir removed" || bad "job-old survived"
[ -d "$WT_BAD" ] && ok "ASK worktree preserved" || bad "unmerged worktree was deleted!"
[ -d "$WT_IGN" ] && [ -f "$WT_IGN/.env" ] && ok "ignored-.env worktree preserved (finding 1)" || bad "wt-ignored deleted with its .env!"
[ -d "$WT_GHOST" ] && ok "no-record-owner worktree preserved" || bad "ghost worktree deleted!"
[ -d "$WT_HID" ] && [ -f "$WT_HID/scratch.txt" ] && ok "hidden-untracked worktree preserved (B1)" || bad "wt-hidden deleted with unseen untracked file!"
[ -f "$WT_DIST/dist/app.js" ] && [ -f "$WT_DIST/target/bin" ] && ok "worktree with ignored dist/target preserved (B3)" || bad "wt-dist deleted with its build output!"
[ -d "$OSRC_HOME/jobs/job-uncollected" ] && ok "uncollected job preserved (finding 4)" || bad "job-uncollected deleted!"
[ -d "$OSRC_HOME/jobs/job-blocked" ] && ok "blocked job evidence preserved (finding 4)" || bad "job-blocked deleted!"
[ -d "$OSRC_HOME/jobs/job-unver" ] && ok "unverified done? job preserved (B4)" || bad "job-unver deleted!"
[ ! -d "$OSRC_HOME/loops/loop-ok" ] && ok "collected success loop removed (B2)" || bad "loop-ok survived"
[ -d "$OSRC_HOME/loops/loop-blocked" ] && ok "blocked loop evidence preserved (B2)" || bad "loop-blocked deleted!"
[ -d "$OSRC_HOME/loops/loop-uncol" ] && ok "uncollected loop preserved (B2)" || bad "loop-uncol deleted!"
[ ! -f "$OSRC_HOME/autodetach/ad-ok.log" ] && [ ! -f "$OSRC_HOME/autodetach/ad-ok.rc" ] \
  && ok "exited-0 autodetach pair removed (B2)" || bad "ad-ok survived"
[ -f "$OSRC_HOME/autodetach/ad-fail.log" ] && [ -f "$OSRC_HOME/autodetach/ad-fail.rc" ] \
  && ok "exit-1 autodetach evidence preserved (B2)" || bad "ad-fail deleted!"
[ -f "$OSRC_HOME/autodetach/ad-noex.log" ] && ok "no-marker autodetach log preserved (B2)" || bad "ad-noex deleted!"
git -C "$R" rev-parse --verify -q refs/heads/outsourcerer/wt-unmerged >/dev/null 2>&1 \
  && ok "unmerged branch preserved" || bad "unmerged branch deleted!"
[ -d "$TMP/outside-dir" ] && ok "outside-manifest path untouched" || bad "outside path deleted!"
[ -d "$OSRC_HOME/jobs/job-liveowner" ] && ok "live-owner dir preserved" || bad "live-owner dir deleted!"
[ -d "$OSRC_HOME/jobs" ] && [ -d "$OSRC_HOME/owners" ] && ok "manifest attack dirs untouched" || bad "attack line deleted a root dir!"
[ -f "$OSRC_HOME/cleanup.log" ] && grep -q 'removed' "$OSRC_HOME/cleanup.log" \
  && ok "deletions logged to cleanup.log" || bad "cleanup.log missing entries"

echo "=== ack + disk gate ==="
gate="$(OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_free_kb() { printf "51200"; }
  _osrc_disk_gate; echo "gate-rc=$?"' 2>&1)"
grep -q 'refusing new lane launches' <<<"$gate" && ok "disk gate refuses under 10GB with unanswered ASK" || bad "gate did not refuse: $gate"
run cleanup --ack >/dev/null 2>&1 && [ -f "$OSRC_HOME/cleanup/ask-ack" ] \
  && ok "--ack writes ask-ack" || bad "--ack did not write ask-ack"
# The gate rescans live, so a matching ack passes even without a state file.
rm -f "$OSRC_HOME/cleanup/state.json"
gate2="$(OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_free_kb() { printf "51200"; }
  _osrc_disk_gate; echo "gate-rc=$?"' 2>&1)"
grep -q 'gate-rc=0' <<<"$gate2" && ok "gate rescans live and passes after ack (finding 8)" || bad "gate still refused after ack: $gate2"
# An ack taken against an older list no longer matches once the list changes:
# a new ASK item appears after the ack, the live rescan sees it, gate refuses.
mkdir -p "$OSRC_HOME/jobs/job-late"; echo blocked > "$OSRC_HOME/jobs/job-late/status"; age2h "$OSRC_HOME/jobs/job-late"
manifest "$OSRC_HOME/jobs/job-late" job job-late ""
gate3="$(OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_free_kb() { printf "51200"; }
  _osrc_disk_gate; echo "gate-rc=$?"' 2>&1)"
grep -q 'refusing new lane launches' <<<"$gate3" && ok "stale ack cannot match a changed list (finding 8)" || bad "gate passed on stale ack: $gate3"
echo "=== 0-ASK disk pressure (finding 8) ==="
mkdir -p "$TMP/osrc2/jobs"
g0="$(OSRC_HOME="$TMP/osrc2" OSRC_SOURCED=1 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_free_kb() { printf "51200"; }
  _osrc_disk_gate; echo "gate-rc=$?"' 2>&1)"
grep -q 'held elsewhere' <<<"$g0" && ok "0-ASK gate names the real problem (finding 8)" || bad "0-ASK gate wrong: $g0"
grep -q 'ack' <<<"$g0" && bad "0-ASK gate demanded an ack of nothing" || ok "0-ASK gate does not demand ack"
a0="$(OSRC_HOME="$TMP/osrc2" bash "$SRC" cleanup --ack 2>&1)"
grep -q 'nothing to acknowledge' <<<"$a0" && ok "--ack on empty list says so (finding 8)" || bad "--ack empty-list wrong: $a0"
[ ! -f "$TMP/osrc2/cleanup/ask-ack" ] && ok "--ack writes nothing for an empty list" || bad "empty-list ack wrote a file"

echo "=== legacy target cleanup (compat) ==="
J="$OSRC_HOME/jobs/job-leg"; mkdir -p "$J"
git -C "$R" worktree add -q "$R/.outsourcerer/worktrees/job-leg" -b outsourcerer/job-leg HEAD
( cd "$R/.outsourcerer/worktrees/job-leg" && printf 'leg-wip\n' > leg.txt && git add leg.txt && git commit -qm leg-wip )
jq -cn --arg p "$R/.outsourcerer/worktrees/job-leg" --arg b outsourcerer/job-leg --arg bs "$(git -C "$R" rev-parse HEAD)" \
  '{path:$p,branch:$b,base_sha:$bs}' > "$J/worktree.json"
leg="$(run cleanup job-leg 2>&1)"; lrc=$?
[ "$lrc" != "0" ] && grep -q 'REFUSING' <<<"$leg" && ok "cleanup <id> refuses unmerged work" || bad "legacy refuse broken (rc=$lrc): $leg"
[ -d "$R/.outsourcerer/worktrees/job-leg" ] && ok "refused worktree still present" || bad "refused worktree vanished"
run cleanup job-leg --force >/dev/null 2>&1
[ ! -d "$R/.outsourcerer/worktrees/job-leg" ] && ok "cleanup <id> --force removes worktree" || bad "force cleanup failed"
git -C "$R" rev-parse --verify -q refs/heads/outsourcerer/job-leg >/dev/null 2>&1 \
  && bad "force cleanup left branch" || ok "force cleanup removed branch"

echo "=== gc compat ==="
OLD="$OSRC_HOME/jobs/job-ancient"; mkdir -p "$OLD"; echo done > "$OLD/status"
RECENT="$OSRC_HOME/jobs/job-fresh"; mkdir -p "$RECENT"; echo done > "$RECENT/status"
RUNNING="$OSRC_HOME/jobs/job-run"; mkdir -p "$RUNNING"; echo running > "$RUNNING/status"
touch -t 202001010000 "$OLD" "$OLD/status" 2>/dev/null
gc_out="$(run gc --older-than 1 2>&1)"
[ ! -d "$OLD" ] && [ -d "$RECENT" ] && [ -d "$RUNNING" ] \
  && ok "gc --older-than 1 removes only old completed jobs" || bad "gc compat broken: $gc_out"

echo "RESULTS: $pass pass $fail fail"
[ "$fail" -eq 0 ]
