#!/usr/bin/env bash
# test_done_contract.sh — the L6 "done" contract for session lanes (lib/done.sh).
#
# An idle delegate can be finished OR stuck halfway; the screen cannot tell them apart, so
# `session start --done-when <spec>` records a machine-checkable contract and `osrc_done_state`
# answers done | not-done | no-contract | error <reason>. This suite proves, with no tmux:
#   1. no contract -> no-contract; bad session name -> error bad-name.
#   2. file:<path> done/not-done, relative to the contract cwd and absolute.
#   3. branch:<b>@<marker> done/not-done, missing branch -> not-done, non-repo cwd -> error.
#   4. check:<cmd> done/not-done, 60 s result cache (counter proves no rerun), cache bypass via
#      OSRC_DONE_CACHE_SECS=0, and the wall-clock bound via OSRC_DONE_CHECK_SECS.
#   5. bad specs -> error bad-spec; osrc_done_set rejects bad name/spec; osrc_done_get round-trips.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
LIB="$HERE/../lib/done.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
[ -f "$LIB" ] || { echo "FAIL: cannot find $LIB"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }
bash -n "$LIB" || { echo "FAIL: bash -n failed for $LIB"; exit 1; }

TMP="$(mktemp -d "$HERE/.test-done-contract.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export OSRC_HOME="$TMP/state"
mkdir -p "$HOME" "$OSRC_HOME"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Source the engine for _timeout/_mkdir_private/_kill_tree, then the module explicitly: when a
# suite sources outsourcerer.sh, $0 is the suite so SCRIPT_DIR does not point at scripts/, and the
# lib/*.sh loader (which keys off $SCRIPT_DIR) cannot find lib/. Production execution resolves
# SCRIPT_DIR correctly; the module itself is what is under test here.
(
  set --
  . "$SRC" >/dev/null 2>&1
  . "$LIB"
  for fn in osrc_done_set osrc_done_get osrc_done_state osrc_done_validate osrc_done_clear; do
    type -t "$fn" >/dev/null || { echo "FAIL: $fn not loaded"; exit 1; }
  done

  WORK="$TMP/work"; mkdir -p "$WORK"

  # --- 1. no contract / bad name -------------------------------------------------------------
  [ "$(osrc_done_state lane-a)" = "no-contract" ] \
    && ok "no contract -> no-contract" || bad "no contract -> $(osrc_done_state lane-a)"
  [ "$(osrc_done_state '../evil')" = "error bad-name" ] \
    && ok "bad name -> error bad-name" || bad "bad name -> $(osrc_done_state '../evil')"
  osrc_done_set '../evil' 'file:x' "$WORK" 2>/dev/null \
    && bad "osrc_done_set accepted a traversal name" || ok "osrc_done_set rejects a traversal name"

  # --- 2. file:<path> -------------------------------------------------------------------------
  osrc_done_set lane-file 'file:marker.txt' "$WORK" || { echo "FAIL: osrc_done_set file spec"; exit 1; }
  [ "$(osrc_done_get lane-file | jq -r .spec)" = "file:marker.txt" ] \
    && [ "$(osrc_done_get lane-file | jq -r .cwd)" = "$WORK" ] \
    && ok "osrc_done_get round-trips spec+cwd" || bad "osrc_done_get round-trip"
  [ "$(osrc_done_state lane-file)" = "not-done" ] \
    && ok "file spec absent -> not-done" || bad "file spec absent -> $(osrc_done_state lane-file)"
  : > "$WORK/marker.txt"
  [ "$(osrc_done_state lane-file)" = "done" ] \
    && ok "file spec present -> done" || bad "file spec present -> $(osrc_done_state lane-file)"
  : > "$WORK/abs-marker"
  osrc_done_set lane-abs "file:$WORK/abs-marker" "$WORK" || exit 1
  [ "$(osrc_done_state lane-abs)" = "done" ] \
    && ok "absolute file path -> done" || bad "absolute file path -> $(osrc_done_state lane-abs)"

  # --- 3. branch:<b>@<marker> ------------------------------------------------------------------
  REPO="$TMP/repo"; mkdir -p "$REPO"
  git -C "$REPO" init -q && git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init --allow-empty
  git -C "$REPO" branch feature
  osrc_done_set lane-branch 'branch:feature@READY' "$REPO" || exit 1
  [ "$(osrc_done_state lane-branch)" = "not-done" ] \
    && ok "branch tip without marker -> not-done" || bad "branch tip without marker -> $(osrc_done_state lane-branch)"
  git -C "$REPO" checkout -q feature
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm "work

READY for review" --allow-empty
  [ "$(osrc_done_state lane-branch)" = "done" ] \
    && ok "branch tip containing READY -> done" || bad "branch tip containing READY -> $(osrc_done_state lane-branch)"
  osrc_done_set lane-nobranch 'branch:no-such@READY' "$REPO" || exit 1
  [ "$(osrc_done_state lane-nobranch)" = "not-done" ] \
    && ok "missing branch -> not-done (not error)" || bad "missing branch -> $(osrc_done_state lane-nobranch)"
  # $TMP lives inside this git worktree, so a "non-repo" cwd must come from outside it.
  NOREPO="$(mktemp -d "${TMPDIR:-/tmp}/osrc-done-norepo.XXXXXX")"
  osrc_done_set lane-norepo 'branch:main@READY' "$NOREPO" || exit 1
  [ "$(osrc_done_state lane-norepo)" = "error not-a-repo" ] \
    && ok "non-repo cwd -> error not-a-repo" || bad "non-repo cwd -> $(osrc_done_state lane-norepo)"
  rm -rf "$NOREPO"
  osrc_done_set lane-gonecwd 'file:x' "$TMP/does-not-exist" || exit 1
  [ "$(osrc_done_state lane-gonecwd)" = "not-done" ] \
    && ok "file spec with missing cwd dir -> not-done" || bad "missing cwd dir -> $(osrc_done_state lane-gonecwd)"

  # --- 4. check:<cmd> + cache + bound ---------------------------------------------------------
  osrc_done_set lane-true 'check:true' "$WORK" || exit 1
  [ "$(osrc_done_state lane-true)" = "done" ] \
    && ok "check:true -> done" || bad "check:true -> $(osrc_done_state lane-true)"
  osrc_done_set lane-false 'check:false' "$WORK" || exit 1
  [ "$(osrc_done_state lane-false)" = "not-done" ] \
    && ok "check:false -> not-done" || bad "check:false -> $(osrc_done_state lane-false)"

  # Cache: a counter proves the second poll inside 60 s does NOT rerun the command.
  CNT="$TMP/count"; : > "$CNT"
  osrc_done_set lane-cache "check:echo x >> '$CNT'" "$WORK" || exit 1
  osrc_done_state lane-cache >/dev/null
  osrc_done_state lane-cache >/dev/null
  [ "$(wc -l < "$CNT" | tr -d ' ')" = "1" ] \
    && ok "check result cached 60 s (command ran once)" || bad "cache: counter=$(wc -l < "$CNT")"
  OSRC_DONE_CACHE_SECS=0 osrc_done_state lane-cache >/dev/null
  [ "$(wc -l < "$CNT" | tr -d ' ')" = "2" ] \
    && ok "OSRC_DONE_CACHE_SECS=0 bypasses the cache" || bad "cache bypass: counter=$(wc -l < "$CNT")"

  # Wall-clock bound: a 30 s sleep under a 1 s cap must come back not-done, quickly.
  osrc_done_set lane-slow 'check:sleep 30' "$WORK" || exit 1
  t0="$(date +%s)"
  _st="$(OSRC_DONE_CHECK_SECS=1 osrc_done_state lane-slow)"
  t1="$(date +%s)"
  [ "$_st" = "not-done" ] && [ $((t1 - t0)) -lt 20 ] \
    && ok "check timeout -> not-done within the bound" || bad "check timeout -> $_st in $((t1-t0))s"

  # --- 5. bad specs / validation ---------------------------------------------------------------
  for badspec in 'bogus' 'file:' 'branch:onlybranch' 'branch:@READY' 'branch:-lead@X' 'check:   ' ''; do
    if osrc_done_validate "$badspec" >/dev/null 2>&1; then
      bad "osrc_done_validate accepted '$badspec'"
    fi
  done
  ok "osrc_done_validate rejects every malformed spec"
  osrc_done_set lane-badspec 'bogus' "$WORK" 2>/dev/null \
    && bad "osrc_done_set accepted a bad spec" || ok "osrc_done_set rejects a bad spec"
  # A hand-edited contract with a bad spec surfaces as error bad-spec, not a crash.
  mkdir -p "$OSRC_HOME/done"
  printf '{"spec":"bogus","cwd":"%s"}\n' "$WORK" > "$OSRC_HOME/done/lane-hand.json"
  [ "$(osrc_done_state lane-hand)" = "error bad-spec" ] \
    && ok "hand-edited bad spec -> error bad-spec" || bad "hand-edited bad spec -> $(osrc_done_state lane-hand)"
  printf 'not json\n' > "$OSRC_HOME/done/lane-broken.json"
  [ "$(osrc_done_state lane-broken)" = "error unreadable-contract" ] \
    && ok "corrupt contract -> error unreadable-contract" || bad "corrupt contract -> $(osrc_done_state lane-broken)"

  # session start rejects a bad --done-when before touching tmux: run the real CLI. Guarded on tmux
  # because `session()` refuses earlier with "tmux not installed" on hosts without it.
  if command -v tmux >/dev/null 2>&1; then
    out="$(OSRC_HOME="$OSRC_HOME" bash "$SRC" session start --done-when bogus 2>&1)"; rc=$?
    case "$out" in *"invalid --done-when spec"*) ok "session start --done-when bogus dies at validation" ;;
      *) bad "session start --done-when bogus: rc=$rc out=$out" ;; esac
    [ "$rc" -ne 0 ] || bad "session start --done-when bogus exited 0"
  else
    echo "SKIP: session start CLI check (no tmux on this host)"
  fi

  osrc_done_clear lane-file
  [ "$(osrc_done_state lane-file)" = "no-contract" ] \
    && [ ! -f "$OSRC_HOME/done/lane-file.checkcache" ] \
    && ok "osrc_done_clear drops contract + cache" || bad "osrc_done_clear"

  echo "done-contract: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
)
rc=$?
exit $rc
