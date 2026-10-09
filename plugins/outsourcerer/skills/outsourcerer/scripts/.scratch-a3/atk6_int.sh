#!/usr/bin/env bash
# atk6_int: Ctrl-C shape — signal the gate's process GROUP while a suite ignores INT.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
SCR="$D/suites"; mkdir -p "$SCR"
have() { command -v "$1" >/dev/null 2>&1; }
. "$D/runner_extract.sh"

cat > "$SCR/intign.sh" <<'EOF'
#!/usr/bin/env bash
trap '' INT TERM   # ignores INT like a wedged tool might
sleep 61.52 & wait
EOF
chmod +x "$SCR/intign.sh"

# The gate runs in the background of THIS script but is the process group leader's
# child; signal the whole group like a terminal would (kill -INT -PGID).
setsid() { :; } 2>/dev/null || true
(
  _run_unit_suite_bounded "$SCR/intign.sh"
  echo "runner_rc=$_suite_rc timed_out=$_suite_timed_out" > "$SCR/int.rc"
) &
gate=$!
# put the gate in its own process group so we can signal the group like a terminal;
# bash & jobs already get their own pgid when job control is on — in a script it is
# off, so signal the gate AND its children via the suite root's pgid instead.
sleep 1
pgid="$(ps -o pgid= -p "$gate" 2>/dev/null | tr -d ' ')"
echo "gate=$gate pgid=$pgid"
kill -INT -"$pgid" 2>/dev/null || kill -INT "$gate"
sleep 2
echo "gate alive: $(kill -0 "$gate" 2>/dev/null && echo Y || echo N)"
echo "int.rc: $(cat "$SCR/int.rc" 2>/dev/null || echo missing)"
left="$(ps -eo pid=,command= | awk '$NF=="61.52" && $(NF-1) ~ /sleep$/ {print $1}')"
echo "sleep 61.52 left: [${left}]"
[ -n "$left" ] && kill -KILL $left 2>/dev/null
wait "$gate" 2>/dev/null
echo DONE
