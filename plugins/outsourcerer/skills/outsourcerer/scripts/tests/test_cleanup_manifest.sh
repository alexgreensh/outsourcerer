#!/usr/bin/env bash
# test_cleanup_manifest.sh -- the created.jsonl manifest cleanup: dry-run SAFE/ASK
# verdicts, --apply deletes SAFE only, --ack, the disk gate, and the legacy
# `cleanup <id> [--force]` worktree path (compat with test_cloud_autoisolate /
# test_hardening expectations).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
have_lsof=0; command -v lsof >/dev/null 2>&1 && have_lsof=1

TMP="$(mktemp -d "$HERE/.cleanup-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc" XDG_CONFIG_HOME="$TMP/xdg"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1 OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
mkdir -p "$HOME" "$OSRC_HOME" "$XDG_CONFIG_HOME" "$OSRC_HOME/jobs"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

run() { OSRC_HOME="$OSRC_HOME" bash "$SRC" "$@"; }
# Age check bypassed for deterministic verdicts; one dedicated check uses the default.
run0() { OSRC_HOME="$OSRC_HOME" OSRC_CLEANUP_MIN_AGE=0 bash "$SRC" "$@"; }

mkrepo() { # <dir> -> repo with one commit on main
  local d="$1"; mkdir -p "$d"; (
    cd "$d" && git init -q
    printf 'v1\n' > app.txt; git add -A; git commit -qm init
  )
}

manifest() { # <path> <kind> <session> <repo>
  jq -cn --arg p "$1" --arg k "$2" --arg s "$3" --arg r "$4" --argjson t "$(date +%s)" \
    '{path:$p,kind:$k,session:$s,repo:$r,ts:$t}' >> "$OSRC_HOME/created.jsonl"
}

echo "=== fixtures ==="
R="$TMP/repo"; mkrepo "$R"
# SAFE worktree: branch at main's HEAD (fully merged), clean tree.
git -C "$R" worktree add -q "$R/.outsourcerer/worktrees/wt-safe" -b outsourcerer/wt-safe 2>/dev/null \
  || git -C "$R" worktree add -q "$R/.outsourcerer/worktrees/wt-safe" -b outsourcerer/wt-safe HEAD
WT_SAFE="$R/.outsourcerer/worktrees/wt-safe"
# ASK worktree: one commit ahead of main, unmerged.
git -C "$R" worktree add -q "$R/.outsourcerer/worktrees/wt-unmerged" -b outsourcerer/wt-unmerged HEAD
WT_BAD="$R/.outsourcerer/worktrees/wt-unmerged"
( cd "$WT_BAD" && printf 'wip\n' > wip.txt && git add wip.txt && git commit -qm wip )
# SAFE plain dir: an old done job dir with a gone owner.
mkdir -p "$OSRC_HOME/jobs/job-old"; echo done > "$OSRC_HOME/jobs/job-old/status"
# ASK dir: files open under it.
mkdir -p "$OSRC_HOME/jobs/job-busy"; echo done > "$OSRC_HOME/jobs/job-busy/status"; printf 'x\n' > "$OSRC_HOME/jobs/job-busy/f"
# ASK: path outside any recorded root.
mkdir -p "$TMP/outside-dir"
# ASK: owner still live (remote lane json, no L2 module -> fallback reads live).
mkdir -p "$OSRC_HOME/remote"; jq -cn '{id:"live-lane",branch:"b",head_ready:false}' > "$OSRC_HOME/remote/live-lane.json"
mkdir -p "$OSRC_HOME/jobs/job-liveowner"; echo done > "$OSRC_HOME/jobs/job-liveowner/status"

manifest "$WT_SAFE" worktree sess-gone "$R"
manifest "outsourcerer/wt-safe" branch sess-gone "$R"
manifest "$WT_BAD" worktree sess-gone "$R"
manifest "outsourcerer/wt-unmerged" branch sess-gone "$R"
manifest "$OSRC_HOME/jobs/job-old" job sess-gone ""
manifest "$OSRC_HOME/jobs/job-busy" job sess-gone ""
manifest "$TMP/outside-dir" job sess-gone ""
manifest "$OSRC_HOME/jobs/job-liveowner" job live-lane ""

echo "=== dry run ==="
out="$(run0 cleanup 2>&1)" || { bad "cleanup dry run failed"; echo "$out"; }
echo "$out" | grep -q 'dry run' && ok "dry run banner" || bad "no dry-run banner: $out"
echo "$out" | grep -q "SAFE.*wt-safe" && ok "merged worktree verdict SAFE" || bad "wt-safe not SAFE: $out"
echo "$out" | grep -q "ASK.*wt-unmerged" && ok "unmerged worktree verdict ASK" || bad "wt-unmerged not ASK: $out"
echo "$out" | grep -q "ASK.*job-busy" && ok "open dir present (verdict depends on lsof)" || true
# Force the busy check deterministically: hold an fd open, re-run.
exec 8< "$OSRC_HOME/jobs/job-busy/f"
out2="$(run0 cleanup 2>&1)"
exec 8<&-
echo "$out2" | grep -q "ASK.*job-busy.*open" && ok "busy dir ASK with 'files open' reason" || bad "busy dir verdict wrong: $(echo "$out2" | grep job-busy)"
echo "$out2" | grep -q "ASK.*outside-dir" && ok "outside-root path ASK" || bad "outside-dir not ASK"
echo "$out2" | grep -q "ASK.*job-liveowner" && ok "live-owner item ASK" || bad "live-owner not ASK"
echo "$out2" | grep -q "SAFE.*job-old" && ok "gone-owner done job SAFE" || bad "job-old not SAFE"
[ -d "$WT_SAFE" ] && [ -d "$WT_BAD" ] && [ -d "$OSRC_HOME/jobs/job-old" ] \
  && ok "dry run deleted nothing" || bad "dry run mutated the filesystem"

echo "=== age gate (default 1h) ==="
fresh_out="$(run cleanup 2>&1)"
echo "$fresh_out" | grep -q "ASK.*younger than 1h" && ok "fresh items ASK as younger-than-1h" || bad "age rule not applied: $(echo "$fresh_out" | grep -c 'younger')"

echo "=== apply ==="
app="$(run0 cleanup --apply 2>&1)" || { bad "cleanup --apply failed"; echo "$app"; }
echo "$app" | grep -q 'removed' && ok "apply reported removals" || bad "apply output: $app"
[ ! -d "$WT_SAFE" ] && ok "SAFE worktree removed" || bad "SAFE worktree still present"
git -C "$R" rev-parse --verify -q refs/heads/outsourcerer/wt-safe >/dev/null 2>&1 \
  && bad "SAFE branch survived apply" || ok "merged branch deleted"
[ ! -d "$OSRC_HOME/jobs/job-old" ] && ok "SAFE job dir removed" || bad "job-old survived"
[ -d "$WT_BAD" ] && ok "ASK worktree preserved" || bad "unmerged worktree was deleted!"
git -C "$R" rev-parse --verify -q refs/heads/outsourcerer/wt-unmerged >/dev/null 2>&1 \
  && ok "unmerged branch preserved" || bad "unmerged branch deleted!"
[ -d "$TMP/outside-dir" ] && ok "outside-manifest path untouched" || bad "outside path deleted!"
[ -d "$OSRC_HOME/jobs/job-liveowner" ] && ok "live-owner dir preserved" || bad "live-owner dir deleted!"
[ -f "$OSRC_HOME/cleanup.log" ] && grep -q 'removed' "$OSRC_HOME/cleanup.log" \
  && ok "deletions logged to cleanup.log" || bad "cleanup.log missing entries"

echo "=== ack + disk gate ==="
# Gate logic first (unanswered ASK must refuse), then --ack, then pass.
gate="$(OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_free_kb() { printf "51200"; }   # 50MB free -> under every threshold
  _osrc_disk_gate; echo "gate-rc=$?"' 2>&1)"
echo "$gate" | grep -q 'refusing new lane launches' && ok "disk gate refuses under 10GB with unanswered ASK" || bad "gate did not refuse: $gate"
run0 cleanup --ack >/dev/null 2>&1 && [ -f "$OSRC_HOME/cleanup/ask-ack" ] \
  && ok "--ack writes ask-ack" || bad "--ack did not write ask-ack"
# After ack the stored ask_hash matches -> gate passes.
gate2="$(OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_free_kb() { printf "51200"; }
  # state.json ask_hash was written by the last scan; ack file holds the same hash.
  _osrc_disk_gate; echo "gate-rc=$?"' 2>&1)"
echo "$gate2" | grep -q 'gate-rc=0' && ok "disk gate passes after --ack" || bad "gate still refused after ack: $gate2"
# No state file at all -> refuse with the 'state unknown' message.
rm -f "$OSRC_HOME/cleanup/state.json"
gate3="$(OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_free_kb() { printf "51200"; }
  _osrc_disk_gate; echo "gate-rc=$?"' 2>&1)"
echo "$gate3" | grep -q 'state is unknown' && ok "gate refuses when cleanup state missing" || bad "gate3 wrong: $gate3"

echo "=== legacy target cleanup (compat) ==="
# Unmerged worktree job: cleanup refuses without --force, removes with it.
J="$OSRC_HOME/jobs/job-leg"; mkdir -p "$J"
git -C "$R" worktree add -q "$R/.outsourcerer/worktrees/job-leg" -b outsourcerer/job-leg HEAD
( cd "$R/.outsourcerer/worktrees/job-leg" && printf 'leg-wip\n' > leg.txt && git add leg.txt && git commit -qm leg-wip )
jq -cn --arg p "$R/.outsourcerer/worktrees/job-leg" --arg b outsourcerer/job-leg --arg bs "$(git -C "$R" rev-parse HEAD)" \
  '{path:$p,branch:$b,base_sha:$bs}' > "$J/worktree.json"
leg="$(run cleanup job-leg 2>&1)"; lrc=$?
[ "$lrc" != "0" ] && echo "$leg" | grep -q 'REFUSING' && ok "cleanup <id> refuses unmerged work" || bad "legacy refuse broken (rc=$lrc): $leg"
[ -d "$R/.outsourcerer/worktrees/job-leg" ] && ok "refused worktree still present" || bad "refused worktree vanished"
run cleanup job-leg --force >/dev/null 2>&1
[ ! -d "$R/.outsourcerer/worktrees/job-leg" ] && ok "cleanup <id> --force removes worktree" || bad "force cleanup failed"
git -C "$R" rev-parse --verify -q refs/heads/outsourcerer/job-leg >/dev/null 2>&1 \
  && bad "force cleanup left branch" || ok "force cleanup removed branch"

echo "=== gc compat ==="
OLD="$OSRC_HOME/jobs/job-ancient"; mkdir -p "$OLD"; echo done > "$OLD/status"
RECENT="$OSRC_HOME/jobs/job-fresh"; mkdir -p "$RECENT"; echo done > "$RECENT/status"
RUNNING="$OSRC_HOME/jobs/job-run"; mkdir -p "$RUNNING"; echo running > "$RUNNING/status"
touch -t 202001010000 "$OLD" 2>/dev/null || touch -d '2020-01-01' "$OLD" 2>/dev/null || true
gc_out="$(run gc --older-than 1 2>&1)"
[ ! -d "$OLD" ] && [ -d "$RECENT" ] && [ -d "$RUNNING" ] \
  && ok "gc --older-than 1 removes only old completed jobs" || bad "gc compat broken: $gc_out"

echo "RESULTS: $pass pass $fail fail"
[ "$fail" -eq 0 ]
