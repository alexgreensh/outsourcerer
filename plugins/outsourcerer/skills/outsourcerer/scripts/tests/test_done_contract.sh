#!/usr/bin/env bash
# test_done_contract.sh — the L6 "done" contract for session lanes (lib/done.sh).
#
# An idle delegate can be finished OR stuck halfway; the screen cannot tell them apart, so
# `session start --done-when <spec>` records a machine-checkable contract and `osrc_done_state`
# answers done | not-done | no-contract | error <reason>. This suite proves, with no tmux:
#   1. no contract -> no-contract; bad session name -> error bad-name.
#   2. file:<path> done/not-done, relative to the contract cwd and absolute.
#   3. branch:<b>@<marker> done/not-done: marker must be a whole word at the start or end of the
#      commit SUBJECT; "NOT READY"/"ALREADY"/mid-subject mentions never count; missing branch ->
#      not-done, non-repo cwd -> error.
#   4. check:<cmd> runs once per lane in the background behind a mkdir lock: callers never block
#      (cached verdict or not-done while in flight), 60 s cache, bypass via OSRC_DONE_CACHE_SECS=0,
#      wall-clock bound via OSRC_DONE_CHECK_SECS, stale-lock break.
#   5. pr:<owner/repo>#<n> done/not-done/error against a stub gh on PATH (never the network),
#      same 60 s cache, errors re-evaluate instead of caching.
#   6. bad specs -> error bad-spec; osrc_done_set rejects bad name/spec; osrc_done_get round-trips.
#   7. loader: lib/done.sh must load when outsourcerer.sh is reached through a symlink, both
#      sourced and executed (LOADER.md).
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

# Source the engine for _timeout/_mkdir_private/_kill_tree. lib/done.sh is pulled in by the
# engine's own _OSRC_FACTORY_DIR loader (BASH_SOURCE + realpath), which still resolves when $0 —
# and so SCRIPT_DIR — points at this test's dir under sourcing. The explicit ". $LIB" is
# deliberately absent: the suite must prove the engine's loader, not a hand-fed source.
(
  set --
  . "$SRC" >/dev/null 2>&1
  for fn in osrc_done_set osrc_done_get osrc_done_state osrc_done_validate osrc_done_clear; do
    type -t "$fn" >/dev/null || { echo "FAIL: $fn not loaded"; exit 1; }
  done

  WORK="$TMP/work"; mkdir -p "$WORK"

  # Poll helpers: check: verdicts land asynchronously when the background runner finishes.
  _poll() { # <name> <want> <ticks-of-0.2s>
    local _i _s=""
    for _i in $(seq 1 "$3"); do
      _s="$(osrc_done_state "$1")"
      [ "$_s" = "$2" ] && break
      sleep 0.2
    done
    printf '%s' "$_s"
  }
  _wait_cache() { # <name> <ticks>
    local _i
    for _i in $(seq 1 "$2"); do
      [ -f "$OSRC_HOME/done/$1.checkcache" ] && return 0
      sleep 0.2
    done
    return 1
  }

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
  # Marker rule: whole word at the START or END of the subject line only.
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm "READY for review" --allow-empty
  [ "$(osrc_done_state lane-branch)" = "done" ] \
    && ok "subject starting with READY -> done" || bad "subject starting with READY -> $(osrc_done_state lane-branch)"
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm "wip: NOT READY, tests still red" --allow-empty
  [ "$(osrc_done_state lane-branch)" = "not-done" ] \
    && ok "mid-subject NOT READY -> not-done" || bad "mid-subject NOT READY -> $(osrc_done_state lane-branch)"
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm "still NOT READY" --allow-empty
  [ "$(osrc_done_state lane-branch)" = "not-done" ] \
    && ok "subject ending in NOT READY -> not-done" || bad "subject ending in NOT READY -> $(osrc_done_state lane-branch)"
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm "shipped the thing READY" --allow-empty
  [ "$(osrc_done_state lane-branch)" = "done" ] \
    && ok "subject ending with READY -> done" || bad "subject ending with READY -> $(osrc_done_state lane-branch)"
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm "it is ALREADY" --allow-empty
  [ "$(osrc_done_state lane-branch)" = "not-done" ] \
    && ok "ALREADY is not the whole word READY -> not-done" || bad "ALREADY -> $(osrc_done_state lane-branch)"
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm "plain subject" -m "READY in body only" --allow-empty
  [ "$(osrc_done_state lane-branch)" = "not-done" ] \
    && ok "marker in body but not subject -> not-done" || bad "body-only marker -> $(osrc_done_state lane-branch)"
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

  # --- 4. check:<cmd>: async, one run per lane behind a lock, cached ---------------------------
  # First poll spawns the background runner and answers not-done (or the last verdict); the real
  # verdict lands in the checkcache when the runner finishes.
  osrc_done_set lane-true 'check:true' "$WORK" || exit 1
  [ "$(_poll lane-true done 50)" = "done" ] \
    && ok "check:true -> done once the background run lands" || bad "check:true -> $(_poll lane-true done 1)"
  osrc_done_set lane-false 'check:false' "$WORK" || exit 1
  [ "$(osrc_done_state lane-false)" = "not-done" ] \
    && ok "check:false first poll -> not-done without blocking" || bad "check:false -> $(osrc_done_state lane-false)"
  _wait_cache lane-false 50 && grep -q ' not-done$' "$OSRC_HOME/done/lane-false.checkcache" \
    && ok "check:false verdict cached after the run" || bad "check:false cache never landed"

  # Two concurrent callers on a 2 s check: neither blocks, the probe runs exactly once.
  CNT="$TMP/count"; : > "$CNT"
  osrc_done_set lane-lock "check:echo x >> '$CNT'; sleep 2" "$WORK" || exit 1
  t0="$(date +%s)"
  s1="$(osrc_done_state lane-lock)"; s2="$(osrc_done_state lane-lock)"
  t1="$(date +%s)"
  [ "$s1" = "not-done" ] && [ "$s2" = "not-done" ] && [ $((t1 - t0)) -lt 2 ] \
    && ok "concurrent polls answer not-done without blocking" || bad "concurrent: '$s1' '$s2' in $((t1-t0))s"
  _wait_cache lane-lock 50
  [ "$(wc -l < "$CNT" | tr -d ' ')" = "1" ] \
    && ok "check ran exactly once behind the lock" || bad "lock: counter=$(wc -l < "$CNT")"
  [ "$(_poll lane-lock done 50)" = "done" ] \
    && ok "lane-lock -> done after the run" || bad "lane-lock never done"
  [ "$(wc -l < "$CNT" | tr -d ' ')" = "1" ] \
    && ok "fresh cache hit does not rerun the check" || bad "cache rerun: counter=$(wc -l < "$CNT")"
  OSRC_DONE_CACHE_SECS=0 osrc_done_state lane-lock >/dev/null   # bypass -> spawns a second run
  for _i in $(seq 1 50); do [ "$(wc -l < "$CNT" | tr -d ' ')" = "2" ] && break; sleep 0.2; done
  [ "$(wc -l < "$CNT" | tr -d ' ')" = "2" ] \
    && ok "OSRC_DONE_CACHE_SECS=0 bypasses the cache" || bad "cache bypass: counter=$(wc -l < "$CNT")"

  # A dead runner's lock (epoch older than bound+60 s) is broken; the check still runs once.
  CNT2="$TMP/count2"; : > "$CNT2"
  osrc_done_set lane-stale "check:echo y >> '$CNT2'" "$WORK" || exit 1
  mkdir -p "$OSRC_HOME/done/lane-stale.checklock"
  printf '%s\n' "$(( $(date +%s) - 400 ))" > "$OSRC_HOME/done/lane-stale.checklock/epoch"
  [ "$(osrc_done_state lane-stale)" = "not-done" ] \
    && ok "stale lock -> caller still answers not-done" || bad "stale lock -> $(osrc_done_state lane-stale)"
  _wait_cache lane-stale 50 && [ "$(wc -l < "$CNT2" | tr -d ' ')" = "1" ] \
    && ok "stale lock broken, check ran once" || bad "stale lock: counter=$(wc -l < "$CNT2")"
  sleep 0.5
  [ ! -d "$OSRC_HOME/done/lane-stale.checklock" ] \
    && ok "lock released after the run" || bad "lock not released"

  # A live lock held by someone else: no second run, answer is last verdict or not-done.
  CNT3="$TMP/count3"; : > "$CNT3"
  osrc_done_set lane-held "check:echo z >> '$CNT3'; sleep 5" "$WORK" || exit 1
  mkdir -p "$OSRC_HOME/done/lane-held.checklock"
  printf '%s\n' "$(date +%s)" > "$OSRC_HOME/done/lane-held.checklock/epoch"
  [ "$(osrc_done_state lane-held)" = "not-done" ] \
    && ok "live lock -> not-done without blocking" || bad "live lock -> $(osrc_done_state lane-held)"
  [ ! -s "$CNT3" ] \
    && ok "live lock: locked-out caller does not run the check" || bad "live lock ran the check"
  rm -rf "$OSRC_HOME/done/lane-held.checklock"

  # While a run is in flight the caller gets the LAST verdict, even a stale one.
  osrc_done_set lane-last 'check:sleep 3' "$WORK" || exit 1
  printf '%s done\n' "$(( $(date +%s) - 120 ))" > "$OSRC_HOME/done/lane-last.checkcache"
  [ "$(osrc_done_state lane-last)" = "done" ] \
    && ok "in-flight run answers the last cached verdict" || bad "in-flight -> $(osrc_done_state lane-last)"

  # Wall-clock bound: sleep 30 under a 1 s cap — the caller returns at once; the runner is
  # killed at the bound and caches not-done ~1 s later, not 30 s later.
  osrc_done_set lane-slow 'check:sleep 30' "$WORK" || exit 1
  t0="$(date +%s)"
  _st="$(OSRC_DONE_CHECK_SECS=1 osrc_done_state lane-slow)"
  t1="$(date +%s)"
  [ "$_st" = "not-done" ] && [ $((t1 - t0)) -lt 20 ] \
    && ok "check timeout -> caller answers not-done immediately" || bad "check timeout -> $_st in $((t1-t0))s"
  _wait_cache lane-slow 50; t3="$(date +%s)"
  [ -f "$OSRC_HOME/done/lane-slow.checkcache" ] && grep -q ' not-done$' "$OSRC_HOME/done/lane-slow.checkcache" \
    && [ $((t3 - t0)) -lt 15 ] \
    && ok "bounded runner caches not-done at the bound, not after 30 s" \
    || bad "slow cache: $(cat "$OSRC_HOME/done/lane-slow.checkcache" 2>/dev/null) at +$((t3-t0))s"

  # --- pr:<owner/repo>#<n> against a stub gh on PATH (never the network) ------------------------
  GHBIN="$TMP/ghbin"; mkdir -p "$GHBIN"
  cat > "$GHBIN/gh" <<'STUB'
#!/usr/bin/env bash
# stub gh: log argv, then emit {"state":"$GH_STUB_STATE"} or fail per GH_STUB_RC / GH_STUB_RAW.
echo "$*" >> "${GH_STUB_LOG:-/dev/null}"
[ "${GH_STUB_RC:-0}" = "0" ] || exit "${GH_STUB_RC:-1}"
if [ -n "${GH_STUB_RAW:-}" ]; then printf '%s\n' "$GH_STUB_RAW"; else printf '{"state":"%s"}\n' "${GH_STUB_STATE:-OPEN}"; fi
STUB
  chmod +x "$GHBIN/gh"
  export GH_STUB_LOG="$TMP/gh.log"; : > "$GH_STUB_LOG"
  export GH_STUB_STATE=OPEN GH_STUB_RC=0
  unset GH_STUB_RAW
  export PATH="$GHBIN:$PATH"

  osrc_done_set lane-pr-open 'pr:octo/repo#42' "$WORK" || exit 1
  [ "$(osrc_done_state lane-pr-open)" = "not-done" ] \
    && ok "pr OPEN -> not-done" || bad "pr OPEN -> $(osrc_done_state lane-pr-open)"
  GH_STUB_STATE=CLOSED
  osrc_done_set lane-pr-closed 'pr:octo/repo#43' "$WORK" || exit 1
  [ "$(osrc_done_state lane-pr-closed)" = "not-done" ] \
    && ok "pr CLOSED -> not-done" || bad "pr CLOSED -> $(osrc_done_state lane-pr-closed)"
  GH_STUB_STATE=MERGED
  osrc_done_set lane-pr-merged 'pr:octo/repo#44' "$WORK" || exit 1
  [ "$(osrc_done_state lane-pr-merged)" = "done" ] \
    && ok "pr MERGED -> done" || bad "pr MERGED -> $(osrc_done_state lane-pr-merged)"
  grep -q 'pr view 44 -R octo/repo --json state' "$GH_STUB_LOG" \
    && ok "stub gh saw the exact pr view argv" || bad "stub gh argv: $(cat "$GH_STUB_LOG")"

  # Cache: second poll inside 60 s must not re-invoke gh.
  : > "$GH_STUB_LOG"
  osrc_done_state lane-pr-merged >/dev/null
  osrc_done_state lane-pr-merged >/dev/null
  [ "$(wc -l < "$GH_STUB_LOG" | tr -d ' ')" = "0" ] \
    && ok "pr result cached 60 s (gh not re-invoked)" || bad "pr cache: gh ran $(wc -l < "$GH_STUB_LOG")x"
  OSRC_DONE_CACHE_SECS=0 osrc_done_state lane-pr-merged >/dev/null
  [ "$(wc -l < "$GH_STUB_LOG" | tr -d ' ')" = "1" ] \
    && ok "OSRC_DONE_CACHE_SECS=0 bypasses the pr cache" || bad "pr cache bypass: $(wc -l < "$GH_STUB_LOG")"

  # gh failing is an error, and errors are NOT cached: fix the stub and the next poll recovers.
  GH_STUB_RC=1
  osrc_done_set lane-pr-fail 'pr:octo/repo#45' "$WORK" || exit 1
  [ "$(osrc_done_state lane-pr-fail)" = "error gh-failed" ] \
    && ok "gh exit!=0 -> error gh-failed" || bad "gh failure -> $(osrc_done_state lane-pr-fail)"
  GH_STUB_RC=0 GH_STUB_STATE=MERGED
  [ "$(osrc_done_state lane-pr-fail)" = "done" ] \
    && ok "gh error not cached (recovers next poll)" || bad "gh error cached: $(osrc_done_state lane-pr-fail)"

  # gh answering non-JSON / a state jq cannot read is also gh-failed, not a silent not-done.
  export GH_STUB_RAW='not json at all'
  osrc_done_set lane-pr-junk 'pr:octo/repo#46' "$WORK" || exit 1
  [ "$(osrc_done_state lane-pr-junk)" = "error gh-failed" ] \
    && ok "gh garbage output -> error gh-failed" || bad "gh garbage -> $(osrc_done_state lane-pr-junk)"
  unset GH_STUB_RAW

  # gh missing entirely: a PATH with jq but no gh anywhere (real gh lives outside /usr/bin).
  osrc_done_set lane-pr-nogh 'pr:octo/repo#47' "$WORK" || exit 1
  JQDIR="$(dirname "$(command -v jq)")"
  [ "$(PATH="/usr/bin:/bin:$JQDIR" osrc_done_state lane-pr-nogh)" = "error gh-missing" ] \
    && ok "gh missing -> error gh-missing" || bad "gh missing -> $(PATH="/usr/bin:/bin:$JQDIR" osrc_done_state lane-pr-nogh)"

  # --- 6. bad specs / validation ---------------------------------------------------------------
  for badspec in 'bogus' 'file:' 'branch:onlybranch' 'branch:@READY' 'branch:-lead@X' 'check:   ' \
                 'pr:' 'pr:noslash#1' 'pr:a/b#' 'pr:a/b#x' 'pr:a/b#1#2' 'pr:/b#1' 'pr:a/#1' 'pr:a b/c#1' ''; do
    if osrc_done_validate "$badspec" >/dev/null 2>&1; then
      bad "osrc_done_validate accepted '$badspec'"
    fi
  done
  ok "osrc_done_validate rejects every malformed spec"
  osrc_done_validate 'pr:octo/repo#42' >/dev/null 2>&1 \
    && ok "osrc_done_validate accepts a well-formed pr spec" || bad "osrc_done_validate rejected pr:octo/repo#42"
  osrc_done_set lane-badspec 'bogus' "$WORK" 2>/dev/null \
    && bad "osrc_done_set accepted a bad spec" || ok "osrc_done_set rejects a bad spec"
  # A hand-edited contract with a bad spec surfaces as error bad-spec, not a crash.
  mkdir -p "$OSRC_HOME/done"
  printf '{"spec":"bogus","cwd":"%s"}\n' "$WORK" > "$OSRC_HOME/done/lane-hand.json"
  [ "$(osrc_done_state lane-hand)" = "error bad-spec" ] \
    && ok "hand-edited bad spec -> error bad-spec" || bad "hand-edited bad spec -> $(osrc_done_state lane-hand)"
  printf '{"spec":"pr:a/b#x","cwd":"%s"}\n' "$WORK" > "$OSRC_HOME/done/lane-handpr.json"
  [ "$(osrc_done_state lane-handpr)" = "error bad-spec" ] \
    && ok "hand-edited bad pr spec -> error bad-spec" || bad "hand-edited bad pr spec -> $(osrc_done_state lane-handpr)"
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

  # --- 7. loader: lib must load through a symlink (LOADER.md) ---------------------------------
  LINKDIR="$TMP/linkdir"; mkdir -p "$LINKDIR"
  ln -s "$SRC" "$LINKDIR/outsourcerer.sh"
  linked="$(
    set --
    OSRC_SOURCED=1
    . "$LINKDIR/outsourcerer.sh" >/dev/null 2>&1
    for fn in osrc_done_set osrc_done_state osrc_done_validate osrc_done_clear _session_record; do
      type -t "$fn" >/dev/null || exit 1
    done
    echo ok
  )"
  [ "$linked" = "ok" ] \
    && ok "lib loads when sourced through a symlink" || bad "lib missing via symlink (sourced): $linked"

  # Executed through the symlink, a bogus --done-when must die at osrc_done_validate — proof the
  # lib loaded. Without it bash reports "osrc_done_validate: command not found" instead.
  if command -v tmux >/dev/null 2>&1; then
    out="$(OSRC_HOME="$OSRC_HOME" bash "$LINKDIR/outsourcerer.sh" session start --done-when bogus 2>&1)"
    case "$out" in
      *"command not found"*) bad "symlinked run: lib not loaded ($out)" ;;
      *"invalid --done-when spec"*) ok "lib loads when executed through a symlink" ;;
      *) bad "symlinked run unexpected output: $out" ;;
    esac
  else
    echo "SKIP: symlinked CLI check (no tmux on this host)"
  fi

  mkdir -p "$OSRC_HOME/done/lane-file.checklock"
  osrc_done_clear lane-file
  [ "$(osrc_done_state lane-file)" = "no-contract" ] \
    && [ ! -f "$OSRC_HOME/done/lane-file.checkcache" ] \
    && [ ! -d "$OSRC_HOME/done/lane-file.checklock" ] \
    && ok "osrc_done_clear drops contract + cache + lock" || bad "osrc_done_clear"

  echo "done-contract: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
)
rc=$?
exit $rc
