#!/usr/bin/env bash
# End to end through the real CLI: plan new -> scout + ship tasks -> plan run --auto-land.
# A fake droid stands in for the model: scouts print a spec, ship workers commit in their worktree.
# Proves the pieces fit: dispatch, worktree isolation, context handoff, done contract, merge gate.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

# Outside this checkout so no worktree or branch can land in the real repo.
E="$(mktemp -d)"; E="$(cd "$E" && pwd -P)"
trap 'rm -rf "$E"' EXIT
export HOME="$E/home" OSRC_HOME="$E/state" GIT_CEILING_DIRECTORIES="$E"
# Lift the launch and pause disk floors for this fake home only (the host's free disk must not decide this test).
mkdir -p "$OSRC_HOME/disk-policy" && printf 'OSRC_DISK_MIN_GB=0\nOSRC_DISK_PAUSE_GB=0\n' > "$OSRC_HOME/disk-policy/settings"
mkdir -p "$HOME" "$E/bin"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

cat > "$E/bin/droid" <<'EOF'
#!/usr/bin/env bash
case "$PWD" in
  */.outsourcerer/worktrees/*)
    echo "feature built" > feature.txt
    git add feature.txt && git -c user.name=t -c user.email=t@t commit -qm "build feature"
    echo "Built feature.txt"; echo "OSRC::DONE built feature" ;;
  *) echo "SPEC: create feature.txt containing the words feature built"; echo "OSRC::DONE spec written" ;;
esac
EOF
chmod +x "$E/bin/droid"

R="$E/repo"; mkdir -p "$R"
git -C "$R" init -q -b main && git -C "$R" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

O() { (cd "$R" && PATH="$E/bin:$PATH" OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 bash "$SRC" "$@"); }

O plan new demo --goal "add a feature file" >/dev/null 2>&1
O task add "write the spec" --shape scout --provider droid >/dev/null 2>&1
O task add "build it" --shape ship --deps t1 --check "test -f feature.txt" --provider droid >/dev/null 2>&1
out="$(O --spend-ok plan run --interval 1 --max-minutes 3 --auto-land 2>&1)"; rc=$?

[ "$rc" -eq 0 ] && ok "plan run finishes with exit 0" || bad "plan run exit $rc: $(printf '%s' "$out" | tail -5)"
T="$OSRC_HOME/plans/demo/tasks"
[ "$(jq -r .state "$T/t1.json")" = done ] && ok "scout task done" || bad "scout state $(jq -r .state "$T/t1.json")"
[ "$(jq -r .state "$T/t2.json")" = done ] && ok "ship task done" || bad "ship state $(jq -r .state "$T/t2.json")"
[ "$(jq -r '.landed // false' "$T/t2.json")" = true ] && ok "ship task landed" || bad "ship task not landed"
grep -q "SPEC: create feature.txt" "$T/t2/brief.md" && ok "the spec reached the build worker's brief" || bad "dependency output missing from brief"
{ _t3b_pipe="$(git -C "$R" log --format=%s main)" && grep -q '^land(demo/t2): build it$' <<<"$_t3b_pipe"; } && ok "main has the land merge commit" || bad "no land commit on main"
[ "$(git -C "$R" show main:feature.txt 2>/dev/null)" = "feature built" ] && ok "the built file is on main" || bad "feature.txt not on main"
[ -z "$(git -C "$R" status --porcelain)" ] && ok "the caller's checkout stayed clean" || bad "caller checkout dirty"
[ "$(jq -r .verdict "$T/t2/evidence.json")" = done ] && [ "$(jq -r .secret_scan "$T/t2/evidence.json")" = clean ] \
  && ok "evidence records the verdict and a clean secret scan" || bad "evidence incomplete"

j2="$(jq -r '.jobs[0] // ""' "$T/t2.json")"
[ -n "$j2" ] && [ "$(cat "$OSRC_HOME/jobs/$j2/task_ref" 2>/dev/null)" = demo/t2 ] \
  && ok "the real launch links its job back to the task" || bad "job $j2 has no task_ref"

if [ "$fail" -gt 0 ]; then
  # A rare first-run failure was seen once and never reproduced; print enough to explain the next one.
  echo "--- diagnostics (plan run rc=$rc) ---"
  printf '%s\n' "$out" | tail -25
  for f in "$T"/t*.json; do jq -c '{id,state,attempts,job,jobs,landed,land_error,result:(.result|.[0:160])}' "$f" 2>/dev/null; done
  tail -20 "$OSRC_HOME/plans/demo/events.jsonl" 2>/dev/null
  for j in $(jq -r '.jobs[]?' "$T"/t*.json 2>/dev/null); do
    echo "job $j: status=$(cat "$OSRC_HOME/jobs/$j/status" 2>/dev/null) reason=$(cat "$OSRC_HOME/jobs/$j/reason" 2>/dev/null) error=$(head -c 300 "$OSRC_HOME/jobs/$j/error" 2>/dev/null)"
  done
  git -C "$R" status --porcelain | head
fi
echo
echo "factory e2e: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
