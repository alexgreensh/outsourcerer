#!/usr/bin/env bash
# test_windows_portability.sh — the tool must work on a filesystem that cannot express
# Unix permission bits (NTFS under Git Bash / MSYS).
#
# Defect A: `mkdir -m 700 DIR` creates the directory and then exits NON-ZERO there, because
# applying the mode fails. Every caller that reads that exit status concludes the directory
# was not created. In the background launcher that meant the atomic job-dir claim looked like
# a collision on every attempt: it retried until it gave up, left an empty directory behind
# per attempt, and reported that no job id could be allocated. The effect is that every
# backgrounded or fanned-out delegation is non-functional on that platform, including plain
# runs that auto-detach.
#
# Defect B: `doctor` declared a variable inside a jq-guarded branch and read it unguarded.
# Under `set -u` that aborts the whole command when jq is absent, so the one command whose
# job is to report a missing dependency dies before it can report it.
#
# The MSYS behaviour is simulated with a mkdir stub rather than described, so these assertions
# fail on a POSIX box when the defect is present.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
export HOME="$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Clear argv before sourcing: the engine runs its dispatcher on "$@", so any argument passed to this
# test would be interpreted as an outsourcerer subcommand and could abort the suite mid-run.
set --
. "$SRC" >/dev/null 2>&1
# Re-arm AFTER sourcing: the engine installs its own EXIT trap, which replaces this one and leaks a
# temp directory per run. Any suite that sources the engine has to take its trap back.
trap cleanup EXIT

for fn in _mkdir_private _mkdir_claim; do
  type "$fn" >/dev/null 2>&1 || { echo "FAIL: $fn not defined"; exit 1; }
done

# A mkdir that behaves like MSYS on NTFS: with -m it still creates the directory, then fails.
# Placed first on PATH so the functions under test call it instead of the real one.
STUB="$TMP/stub"; mkdir -p "$STUB"
REAL_MKDIR="$(command -v mkdir)"
cat > "$STUB/mkdir" <<EOF
#!/usr/bin/env bash
# Mimic MSYS on a filesystem with no Unix permission bits.
args=(); mode_requested=0
while [ \$# -gt 0 ]; do
  case "\$1" in
    -m) mode_requested=1; shift 2 ;;
    -m*) mode_requested=1; shift ;;
    *) args+=("\$1"); shift ;;
  esac
done
"$REAL_MKDIR" "\${args[@]+\${args[@]}}"; rc=\$?
[ "\$mode_requested" = "1" ] && exit 1
exit \$rc
EOF
chmod +x "$STUB/mkdir"

# Sanity-check the stub itself, so a broken stub cannot masquerade as a passing fix.
( PATH="$STUB:$PATH"; mkdir -m 700 "$TMP/stubcheck" 2>/dev/null )
rc=$?
if [ "$rc" -ne 0 ] && [ -d "$TMP/stubcheck" ]; then
  ok "stub reproduces MSYS behaviour (dir created, exit $rc)"
else
  bad "stub does not reproduce MSYS behaviour (rc=$rc, dir exists: $([ -d "$TMP/stubcheck" ] && echo yes || echo no))"
fi

# ------------------------------------------------------------- DEFECT A, unit
( PATH="$STUB:$PATH"; _mkdir_private "$TMP/state/nested" ) \
  && ok "_mkdir_private succeeds where the mode cannot be applied" \
  || bad "_mkdir_private reports failure for a directory it created"
[ -d "$TMP/state/nested" ] && ok "_mkdir_private created the directory" \
                           || bad "_mkdir_private did not create the directory"

( PATH="$STUB:$PATH"; _mkdir_claim "$TMP/claim-a" ) \
  && ok "_mkdir_claim succeeds where the mode cannot be applied" \
  || bad "_mkdir_claim reports failure for a directory it created"

# Atomicity must survive the fix: a claim on an existing directory must still be refused,
# otherwise two concurrent launches could share one job directory.
_mkdir_claim "$TMP/claim-b" >/dev/null 2>&1
if _mkdir_claim "$TMP/claim-b" >/dev/null 2>&1; then
  bad "_mkdir_claim granted a directory that already existed (lock semantics lost)"
else
  ok "_mkdir_claim refuses a directory that already exists (lock semantics intact)"
fi
# Same under the stub, where the mode failure must not be mistaken for a successful claim.
if ( PATH="$STUB:$PATH"; _mkdir_claim "$TMP/claim-b" ) >/dev/null 2>&1; then
  bad "_mkdir_claim granted an existing directory under the MSYS stub"
else
  ok "_mkdir_claim refuses an existing directory under the MSYS stub"
fi

# Concurrency: many racers, exactly one winner.
#
# The racers must be released from a BARRIER. Simply backgrounding ten subshells does not create a
# race: process startup serializes them so completely that even a deliberately non-atomic
# test-then-create claim wins exactly once every time. An assertion like that certifies the one
# property it cannot observe. Pre-forking the racers and holding them on a shared start flag makes
# them contend for real, and the control below is what proves the assertion has teeth.
_race_round() {   # <claim-fn> <dir> -> prints the number of winners
  local fn="$1" d="$2"
  local won="$TMP/wins.$$.txt" flag="$TMP/go.$$"
  : > "$won"; rm -f "$flag"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ( while [ ! -f "$flag" ]; do :; done
      "$fn" "$d" >/dev/null 2>&1 && printf 'win\n' >> "$won" ) &
  done
  sleep 0.3          # let every racer reach the spin before the gun
  : > "$flag"
  wait
  grep -c 'win' "$won" 2>/dev/null || printf '0'
}

# A deliberately non-atomic claim, used only to prove the assertion can fail. It must NOT create
# with bare `mkdir`: that syscall is atomic no matter how the check around it is written, so a
# test-then-`mkdir` still yields exactly one winner and would make a useless control. `mkdir -p`
# succeeds for every racer, which is the shape of the plausible regression here — someone "fixing"
# the Windows exit-status problem by reaching for -p and losing the lock.
_broken_claim() { [ -d "$1" ] && return 1; mkdir -p "$1" 2>/dev/null || return 1; return 0; }

rounds=20; bad_rounds=0
for r in $(seq 1 $rounds); do
  n="$(_race_round _mkdir_claim "$TMP/race-$r")"
  [ "$n" = "1" ] || bad_rounds=$((bad_rounds+1))
done
[ "$bad_rounds" -eq 0 ] && ok "exactly one concurrent claimant wins, over $rounds contended rounds" \
                        || bad "$bad_rounds/$rounds contended rounds did not produce exactly 1 winner"

# Control: the same harness must CATCH a non-atomic claim. If it cannot, the assertion above is
# decorative and must not be read as evidence of atomicity.
ctl_bad=0
for r in $(seq 1 $rounds); do
  n="$(_race_round _broken_claim "$TMP/broken-$r")"
  [ "$n" = "1" ] || ctl_bad=$((ctl_bad+1))
done
[ "$ctl_bad" -gt 0 ] && ok "control: the race harness catches a non-atomic claim ($ctl_bad/$rounds rounds)" \
                     || bad "control: a non-atomic claim passed all $rounds rounds — the concurrency assertion has no power"

# ------------------------------------------------- POSIX hardening not regressed
# `case`, not `[ ... != "MINGW"* ]`: test(1) does not pattern-match, so the bracket form compares
# against the literal string "MINGW*" and is TRUE on Git Bash, running this block on the one platform
# it exists to skip. The unquoted `*` also globs against the cwd, so a directory containing two
# MINGW-prefixed files makes `[` abort with "too many arguments" and silently skips both assertions.
# Mirrors the engine's own platform detection.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    ok "POSIX mode assertions skipped (no Unix permission bits on this platform)" ;;
  *)
    _mkdir_private "$TMP/posix-priv" >/dev/null 2>&1
    _mkdir_claim   "$TMP/posix-claim" >/dev/null 2>&1
    for d in posix-priv posix-claim; do
      m="$(stat -c '%a' "$TMP/$d" 2>/dev/null || stat -f '%Lp' "$TMP/$d" 2>/dev/null)"
      [ "$m" = "700" ] && ok "POSIX mode still 700 for $d" || bad "POSIX mode for $d is $m, expected 700"
    done
    # The mode must be private from the MOMENT of creation, not merely by the time the helper
    # returns. Creating under a permissive umask and narrowing afterwards leaves a window in which
    # another user can act inside a state or job directory.
    #
    # Asserting the mode after the helper returns does NOT test this: the trailing chmod produces
    # 700 whether or not creation was private, so such an assertion passes identically with the
    # window open. To observe creation itself, neutralise the chmod (a no-op stub on PATH) and run
    # under a hostile umask. What remains is the mode the directory was BORN with.
    CHSTUB="$TMP/chstub"; mkdir -p "$CHSTUB"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$CHSTUB/chmod"; chmod +x "$CHSTUB/chmod"
    ( PATH="$CHSTUB:$PATH"; umask 000; _mkdir_private "$TMP/posix-born" >/dev/null 2>&1 )
    m="$(stat -c '%a' "$TMP/posix-born" 2>/dev/null || stat -f '%Lp' "$TMP/posix-born" 2>/dev/null)"
    [ "$m" = "700" ] && ok "directory is born private under a hostile umask (no creation window)" \
                     || bad "born with mode $m under umask 000, expected 700 (creation window open)"
    ( PATH="$CHSTUB:$PATH"; umask 000; _mkdir_claim "$TMP/claim-born" >/dev/null 2>&1 )
    m="$(stat -c '%a' "$TMP/claim-born" 2>/dev/null || stat -f '%Lp' "$TMP/claim-born" 2>/dev/null)"
    [ "$m" = "700" ] && ok "claimed directory is born private under a hostile umask" \
                     || bad "claimed dir born with mode $m under umask 000, expected 700"
    ;;
esac

# ------------------------------------------------------- DEFECT A, source-level
# Any surviving `mkdir -m` / `mkdir -p -m` whose exit status is consumed reintroduces the bug.
# Match the whole bug CLASS, not one spelling. The mode can be requested as -m 700, -m 0700,
# -m u=rwx, or -pm 700, and `install -d -m` has the same problem. There is no legitimate
# mode-at-creation call left in this script, so any hit is a regression regardless of whether the
# exit status is consumed on the same line (it may be consumed on the next one, via $?).
offenders="$(grep -nE '(mkdir[^|;&]*-p?m?[[:space:]]*-?m[[:space:]]*[0-7ugoa=]|install[^|;&]*-m[[:space:]]*[0-7])' "$SRC" \
             | grep -v '^[0-9]*:[[:space:]]*#' || true)"
[ -z "$offenders" ] && ok "no mode-at-creation mkdir/install remains in the script" \
  || { bad "mode-at-creation call still present (reintroduces the Windows exit-status bug)"; printf '%s\n' "$offenders" | sed 's/^/      /'; }

# The atomic claim must not have been relaxed into a test-then-create race.
grep -qE '\[ +-d +"\$(jd|1)" +\] *(&&|\|\|) *mkdir' "$SRC" \
  && bad "job-dir claim looks like a test-then-create race" \
  || ok "job-dir claim is not a test-then-create race"

# ------------------------------------------------------------------- DEFECT B
# The version-drift local must be initialised, not merely declared, or reading it under
# `set -u` aborts doctor on a machine without jq.
if grep -qE 'local _dver=[^ ]|local _dver="" ' "$SRC" || grep -qE 'local _dver="?"?[ ;]' "$SRC"; then
  ok "doctor's version-drift variable is initialised"
else
  bad "doctor's version-drift variable is declared without a value (unbound under set -u)"
fi

# Behavioural proof: with jq hidden, reading the variable must not abort under set -u.
#
# The probe must be SEEDED with every global the extracted lines read ($SCRIPT_PATH, $OSRC_VERSION).
# Without them the probe aborts on an unbound $SCRIPT_PATH before it ever reaches _dver, and returns
# non-zero for a reason that has nothing to do with the defect. Accepting that non-zero as a pass
# makes the assertion decorative: it then reports success identically whether the fix is present or
# reverted. Only rc=0 is a pass.
#
# Bash version note: this discriminates on bash >= 4.4 (Git Bash, most Linux). On the bash 3.2 that
# ships with macOS a bare `local x` yields an empty value rather than an unset one, so the defect
# does not trip `set -u` there and the probe passes either way. The static assertion above is what
# guards the regression on those hosts.
_dver_probe() {  # <src> -> prints rc=<n>
  local p="$TMP/dver_probe.sh"
  {
    echo 'set -uo pipefail'
    echo 'SCRIPT_PATH="/nonexistent/outsourcerer.sh"'
    echo 'OSRC_VERSION="0.0.0"'
    echo 'have() { return 1; }   # simulate: jq absent'
    echo 'probe() {'
    # Anchor to the CODE line, not the first textual match. The fix's own explanatory comment
    # contains the phrase "local _dver", so a bare grep now selects a comment and the extracted
    # window never reaches the read that triggers the defect.
    sed -n "$(grep -nE '\{ *local _dver' "$1" | head -1 | cut -d: -f1),+4p" "$1" | sed 's/^  *{ *//'
    echo '}'
    echo 'probe; echo "rc=$?"'
  } > "$p"
  bash "$p" 2>&1
}
# Discriminate on the UNBOUND-VARIABLE error, not on the exit status. The extracted block legitimately
# ends non-zero when jq is absent (its final test is simply false, because no version was read), so a
# non-zero rc is the healthy case here and treating it as failure — or as success — says nothing.
# What only ever appears when the defect is present is `set -u` aborting on the unset variable.
out="$(_dver_probe "$SRC")"
case "$out" in
  *"unbound variable"*) bad "version-drift check hits an unbound variable with jq missing" ;;
  *)                    ok "version-drift check survives a missing jq (no unbound variable)" ;;
esac
# The extracted window must actually contain the read that triggers the defect. Without this the
# probe can be green because it captured the wrong lines entirely.
_dver_window() { sed -n "$(grep -nE '\{ *local _dver' "$SRC" | head -1 | cut -d: -f1),+4p" "$SRC"; }
_dver_window | grep -q '\[ -n "\$_dver" \]' \
  && ok "probe window contains the unguarded read of _dver" \
  || bad "probe window does NOT contain the read of _dver — it is testing the wrong lines"

# Negative control: the probe must FAIL against a source with the defect reintroduced, or it is
# proving nothing. Skipped where the shell cannot express the defect (bash 3.2, see note above).
if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }; then
  buggy="$TMP/buggy_src.sh"
  sed 's/local _dver="" /local _dver /' "$SRC" > "$buggy"
  if grep -q 'local _dver ' "$buggy"; then
    out_bug="$(_dver_probe "$buggy")"
    case "$out_bug" in
      *"unbound variable"*) ok "control: probe catches the reintroduced defect" ;;
      *)                    bad "control: probe PASSES with the defect reintroduced — it proves nothing" ;;
    esac
  else
    bad "control: could not reintroduce the defect (source shape changed)"
  fi
else
  ok "control skipped: bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]} cannot express the defect (static assertion covers it)"
fi

OSRC_PLATFORM=windows
if _heartbeat_claim 123 'Thu Jul 31 01:02:03 2026' win-test "" >/dev/null 2>&1; then
  bad "Windows heartbeat claim mutated ownership"
else
  ok "Windows heartbeat claim is observation-only"
fi
if _session_model_restore devin tmux:win fable restore.win win >/dev/null 2>&1; then
  bad "Windows model restore emitted terminal input"
else
  ok "Windows model restore is observation-only"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
